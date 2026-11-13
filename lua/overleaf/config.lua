local M = {}

M._config = {
  env_file = '.env',
  cookie = nil,
  node_path = 'node',
  base_url = 'https://www.overleaf.com', -- Overleaf instance URL (for self-hosted)
  pdf_viewer = nil, -- PDF viewer command (nil = auto-detect: 'open' on macOS, 'xdg-open' on Linux)
  pdf_dir = nil, -- PDF output directory (nil = system temp dir)
  sync_dir = nil, -- Local file sync directory (nil = disabled; enables external tool integration)
  log_level = 'info', -- minimum level shown on screen: 'debug', 'info', 'warn', 'error'
  log_file_level = 'debug', -- minimum level written to the log file ('off' disables it)
  log_file = nil, -- nil = stdpath('state')/overleaf.log
  popup_ms = 12000, -- how long long warn/error popups stay open (ms)
}

function M.setup(opts)
  if opts then
    for k, v in pairs(opts) do
      M._config[k] = v
    end
  end
end

function M.get() return M._config end

function M.load_cookie()
  if M._config.cookie then return M._config.cookie end

  local env_file = M._config.env_file
  local paths

  if env_file:sub(1, 1) == '/' then
    -- Absolute path: use directly
    paths = { env_file }
  else
    -- Relative path: try cwd, then plugin root
    paths = {
      vim.fn.getcwd() .. '/' .. env_file,
      M.plugin_root() .. '/' .. env_file,
    }
  end

  for _, path in ipairs(paths) do
    local f = io.open(path, 'r')
    if f then
      for line in f:lines() do
        local key, value = line:match('^([^=]+)=(.+)$')
        if key == 'OVERLEAF_COOKIE' then
          M._config.cookie = value
          f:close()
          return value
        end
      end
      f:close()
    end
  end

  return nil
end

function M.plugin_root()
  -- Resolve plugin root from this file's location
  local source = debug.getinfo(1, 'S').source:sub(2)
  -- source = /path/to/overleaf-neovim/lua/overleaf/config.lua
  return vim.fn.fnamemodify(source, ':h:h:h')
end

function M.bridge_script() return M.plugin_root() .. '/node/bridge.js' end

local LEVELS = { debug = 0, info = 1, warn = 2, error = 3, off = 99 }
local VIM_LEVELS = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}
local POPUP_HL = { warn = 'DiagnosticWarn', error = 'DiagnosticError' }

--- Path of the log file (full, untruncated messages)
function M.log_path() return M._config.log_file or (vim.fn.stdpath('state') .. '/overleaf.log') end

-- Floating popups for long warn/error messages, stacked top-right
local popups = {}

local function reflow()
  local row = 1
  for _, p in ipairs(popups) do
    if vim.api.nvim_win_is_valid(p.win) then
      pcall(vim.api.nvim_win_set_config, p.win, {
        relative = 'editor',
        row = row,
        col = math.max(0, vim.o.columns - p.width - 2),
      })
      row = row + p.height + 2
    end
  end
end

local function close_popup(p)
  if vim.api.nvim_win_is_valid(p.win) then pcall(vim.api.nvim_win_close, p.win, true) end
  for i, q in ipairs(popups) do
    if q == p then
      table.remove(popups, i)
      break
    end
  end
  reflow()
end

local function show_popup(level, text)
  local width = math.min(math.max(40, math.floor(vim.o.columns * 0.5)), math.max(20, vim.o.columns - 6))
  local lines = vim.split(text, '\n', { plain = true })

  local height = 0
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  height = math.max(1, math.min(height, math.floor(vim.o.lines * 0.6)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = 'editor',
    row = 1,
    col = math.max(0, vim.o.columns - width - 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    noautocmd = true,
    zindex = 250,
    title = ' overleaf ' .. level .. ' ',
    title_pos = 'left',
  })
  if not ok then
    -- Could not open a float: fall back to a one-line notification
    vim.notify('[overleaf] ' .. (text:gsub('%s*\n%s*', ' | ')), VIM_LEVELS[level])
    return
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'FloatBorder:' .. (POPUP_HL[level] or 'DiagnosticInfo') .. ',FloatTitle:' .. (POPUP_HL[level] or 'DiagnosticInfo')

  local p = { win = win, width = width, height = height }
  table.insert(popups, p)
  reflow()
  vim.defer_fn(function() close_popup(p) end, M._config.popup_ms or 12000)
end

--- Log a message. Everything at or above `log_file_level` goes to the log file
--- (full text). On screen, nothing can trigger the "Press ENTER" prompt:
---  * info/debug: one short truncated line
---  * warn/error: the FULL text; a short message uses vim.notify, a long or
---    multi-line one opens a self-closing popup
function M.log(level, msg, ...)
  local target = LEVELS[level] or LEVELS.info

  local ok, formatted = pcall(string.format, msg, ...)
  if not ok then formatted = tostring(msg) end

  -- File: full message
  if target >= (LEVELS[M._config.log_file_level] or LEVELS.debug) then
    local f = io.open(M.log_path(), 'a')
    if f then
      f:write(('%s [%s] %s\n'):format(os.date('%H:%M:%S'), level, formatted))
      f:close()
    end
  end

  -- Screen
  if target >= (LEVELS[M._config.log_level] or LEVELS.warn) then
    local one_line = formatted:gsub('%s*\n%s*', ' | ')
    local max = math.max(20, vim.o.columns - 25)
    local fits = formatted:find('\n', 1, true) == nil and vim.fn.strchars(formatted) <= max

    vim.schedule(function()
      if target >= LEVELS.warn then
        if fits then
          vim.notify('[overleaf] ' .. formatted, VIM_LEVELS[level])
        else
          show_popup(level, formatted)
        end
      else
        local line = one_line
        if vim.fn.strchars(line) > max then line = vim.fn.strcharpart(line, 0, max - 1) .. '…' end
        vim.notify('[overleaf] ' .. line, VIM_LEVELS[level] or vim.log.levels.INFO)
      end
    end)
  end
end

--- Open the full log file in a split
function M.show_log() vim.cmd('botright split ' .. vim.fn.fnameescape(M.log_path()) .. ' | normal! G') end

return M
