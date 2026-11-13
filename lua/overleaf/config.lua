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

--- Path of the log file (full, untruncated messages)
function M.log_path() return M._config.log_file or (vim.fn.stdpath('state') .. '/overleaf.log') end

--- Log a message. Everything at or above `log_file_level` goes to the log file;
--- everything at or above `log_level` is shown on screen as ONE short line, so it
--- can never trigger the "Press ENTER" prompt.
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

  -- Screen: one line, truncated, deferred out of whatever command is running
  if target >= (LEVELS[M._config.log_level] or LEVELS.warn) then
    local line = formatted:gsub('%s*\n%s*', ' | ')
    local max = math.max(20, vim.o.columns - 25)
    if vim.fn.strchars(line) > max then line = vim.fn.strcharpart(line, 0, max - 1) .. '…' end
    vim.schedule(function() vim.notify('[overleaf] ' .. line, VIM_LEVELS[level] or vim.log.levels.INFO) end)
  end
end

return M
