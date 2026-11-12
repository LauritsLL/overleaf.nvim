local ot = require('overleaf.ot')
local config = require('overleaf.config')

local M = {}

local undo_ns = vim.api.nvim_create_namespace('overleaf_undo')

-- (Re)create the extmark tracking `text` that currently sits at (sr, sc).
local function set_mark(bufnr, id, sr, sc, text)
  local lines = vim.split(text, '\n', { plain = true })
  local opts = { id = id }
  if text == '' then
    opts.right_gravity = false
  else
    opts.end_row = sr + #lines - 1
    opts.end_col = (#lines == 1) and (sc + #lines[1]) or #lines[#lines]
    opts.right_gravity, opts.end_right_gravity = true, false
  end
  return vim.api.nvim_buf_set_extmark(bufnr, undo_ns, sr, sc, opts)
end

local function mark_span(bufnr, id)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, undo_ns, id, { details = true })
  if #m == 0 then return end
  local d = m[3] or {}
  return m[1], m[2], d.end_row or m[1], d.end_col or m[2]
end

--- Record one local change (called from _sync).
function M._undo_record(doc, old, new, ops)
  local bufnr = doc.bufnr
  local u = doc.undo_state or { undo = {}, redo = {} }
  doc.undo_state = u

  local del, ins = '', ''
  for _, op in ipairs(ops) do
    if op.d then del = op.d end
    if op.i then ins = op.i end
  end
  local sr, sc = ot.byte_offset_to_pos(new, ot.char_to_byte(old, ops[1].p))

  for _, e in ipairs(u.redo) do pcall(vim.api.nvim_buf_del_extmark, bufnr, undo_ns, e.mark) end
  u.redo = {}

  -- Coalesce consecutive typing / backspacing into one undo step
  local prev = u.undo[#u.undo]
  local fresh = prev and not doc._undo_seal and (vim.uv.now() - prev.t) < 1000
  doc._undo_seal = false
  if fresh then
    local psr, psc, per, pec = mark_span(bufnr, prev.mark)
    if psr then
      if del == '' and prev.orig == '' and sr == per and sc == pec then
        prev.cur = prev.cur .. ins
        set_mark(bufnr, prev.mark, psr, psc, prev.cur)
        prev.t = vim.uv.now()
        return
      elseif ins == '' and prev.cur == '' and sr == psr and sc == psc
          and vim.fn.mode():sub(1, 1) == 'i' then
        prev.orig = del .. prev.orig
        prev.t = vim.uv.now()
        return
      end
    end
  end

  -- cur = text currently in the buffer at the mark, orig = what it replaced
  table.insert(u.undo, { mark = set_mark(bufnr, nil, sr, sc, ins), cur = ins, orig = del, t = vim.uv.now() })
end

-- Swap the tracked region's text for `orig`; returns the reversed entry.
local function flip(doc, e)
  local bufnr = doc.bufnr
  local sr, sc, er, ec = mark_span(bufnr, e.mark)
  if not sr then return end
  local cur = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
  if cur ~= e.cur then return end -- a collaborator touched this text

  vim.api.nvim_buf_del_extmark(bufnr, undo_ns, e.mark)
  doc._undo_busy = true
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, vim.split(e.orig, '\n', { plain = true }))
  pcall(M._sync, doc, bufnr) -- submit the op now, without recording a new entry
  doc._undo_busy = false
  pcall(vim.api.nvim_win_set_cursor, 0, { sr + 1, sc })
  return { mark = set_mark(bufnr, nil, sr, sc, e.orig), cur = e.orig, orig = e.cur, t = 0 }
end

function M.undo_redo(doc, redo)
  if not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then return end
  M._sync(doc, doc.bufnr) -- flush pending local edits into the stack first
  doc._undo_seal = true
  local u = doc.undo_state
  if not u then return end
  local from, to = u.undo, u.redo
  if redo then from, to = u.redo, u.undo end
  while #from > 0 do
    local flipped = flip(doc, table.remove(from))
    if flipped then table.insert(to, flipped) return end
    vim.notify('[overleaf] skipped a step: a collaborator edited that text', vim.log.levels.INFO)
  end
  vim.notify(redo and 'Already at newest change' or 'Already at oldest change')
end

function M.setup_undo(bufnr, doc)
  vim.bo[bufnr].undolevels = -1 -- Vim's own undo would also revert collaborators
  vim.bo[bufnr].undofile = false
  local function map(lhs, redo)
    vim.keymap.set('n', lhs, function()
      local n = vim.v.count1
      for _ = 1, n do M.undo_redo(doc, redo) end
    end, { buffer = bufnr, desc = redo and 'Overleaf redo' or 'Overleaf undo' })
  end
  map('u', false)
  map('<C-r>', true)
  vim.api.nvim_create_autocmd('InsertLeave', {
    buffer = bufnr,
    callback = function() doc._undo_seal = true end,
  })
end

--- Create a Neovim buffer for an Overleaf document
---@param doc table Document instance
---@param lines string[] document lines
---@return number bufnr
function M.create(doc, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, require('overleaf.sync').buf_name(doc.path))

  -- Buffer options first
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false

  -- Set content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Clear undo history so 'u' doesn't wipe the buffer after initial load.
  local old_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { ' ' })
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 1, { '' })
  vim.bo[bufnr].undolevels = old_undolevels
  vim.bo[bufnr].modified = false

  doc.bufnr = bufnr

  -- :w clears modified flag and triggers compile (changes are already synced via OT)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
      require('overleaf').compile()
    end,
  })

  -- Attach change detection
  M.attach(bufnr, doc)

  -- Collaborator-safe undo (turns off Vim's own undo for this buffer)
  M.setup_undo(bufnr, doc)

  -- Verify buffer matches doc.content after undo-clear
  doc:check_content()

  -- Open buffer in current window FIRST (so FileType autocmds fire on current buffer)
  vim.api.nvim_set_current_buf(bufnr)

  -- Editor window options
  local winnr = vim.api.nvim_get_current_win()
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
  vim.wo[winnr].number = true

  -- Set filetype AFTER buffer is current (triggers FileType autocmds for treesitter, copilot, etc.)
  local ext = doc.path:match('%.([^%.]+)$')
  local ft_map = {
    tex = 'tex',
    sty = 'tex',
    cls = 'tex',
    bib = 'bib',
    bbl = 'tex',
    txt = 'text',
    md = 'markdown',
  }

  -- Tell VimTeX which file is the project root BEFORE the FileType event fires.
  if ft_map[ext] == 'tex' then
    local sync_mod = require('overleaf.sync')
    if sync_mod._sync_dir then
      local ol = require('overleaf')
      local main_entry = ol._get_main_tex_entry and ol._get_main_tex_entry()
      if main_entry then
        local main_path = sync_mod._sync_dir .. '/' .. main_entry.path
        vim.b[bufnr].vimtex_main = main_path
        config.log('debug', 'vimtex_main = %s', main_path)
      end
    end
  end

  if ft_map[ext] then vim.bo[bufnr].filetype = ft_map[ext] end

  -- Start syntax highlighting and LSP
  config.log('debug', 'Buffer create: ext=%s ft=%s', tostring(ext), tostring(ft_map[ext]))
  if ft_map[ext] then
    local ts_lang_map = { tex = 'latex', bib = 'bibtex' }
    local lang = ts_lang_map[ft_map[ext]] or ft_map[ext]
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local ok = pcall(vim.treesitter.start, bufnr, lang)
      if not ok then pcall(vim.cmd, 'syntax enable') end

      config.log('info', 'Attaching LSP for ft=%s bufnr=%d', ft_map[ext], bufnr)
      M._attach_lsp(bufnr, ft_map[ext])

      if ft_map[ext] == 'tex' then
        M._run_chktex(bufnr)
        vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
          buffer = bufnr,
          callback = function() M._schedule_lint(bufnr) end,
        })
      end
    end)
  end

  return bufnr
end

--- Manually attach LSP servers to an Overleaf buffer
function M._attach_lsp(bufnr, ft)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- LSP language IDs differ from Neovim filetypes
  local lang_id_map = { tex = 'latex', bib = 'bibtex' }

  local servers = {}
  if ft == 'tex' or ft == 'bib' then
    table.insert(servers, {
      name = 'harper_ls',
      cmd = { 'harper-ls', '--stdio' },
      settings = {
        ['harper-ls'] = {
          linters = { spell_check = true, sentence_capitalization = false },
        },
      },
    })
    table.insert(servers, {
      name = 'ltex',
      cmd = { 'ltex-ls' },
      settings = { ltex = { language = 'en-US' } },
    })
    if ft == 'tex' then table.insert(servers, { name = 'texlab', cmd = { 'texlab' } }) end
  end

  -- Mason installs to ~/.local/share/nvim/mason/bin/
  local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/'

  for _, srv in ipairs(servers) do
    local cmd = srv.cmd[1]
    -- Check system PATH and mason bin
    if vim.fn.executable(cmd) ~= 1 then
      local mason_cmd = mason_bin .. cmd
      if vim.fn.executable(mason_cmd) == 1 then srv.cmd[1] = mason_cmd end
    end
    -- Skip if command not found anywhere
    if vim.fn.executable(srv.cmd[1]) ~= 1 then
      config.log('debug', 'LSP %s not found, skipping', srv.name)
    else
      pcall(vim.lsp.start, {
        name = srv.name,
        cmd = srv.cmd,
        root_dir = vim.fn.getcwd(),
        settings = srv.settings,
        get_language_id = function(_, filetype) return lang_id_map[filetype] or filetype end,
      }, { bufnr = bufnr })
    end
  end
end

--- Attach on_bytes listener to buffer for change detection.
---
--- Rather than computing ops from on_bytes' byte_offset arguments (which is
--- fragile under rapid multi-step edits such as UltiSnips snippet expansion,
--- where a partial/dropped on_bytes causes doc.content to silently diverge
--- from the buffer), we defer to vim.schedule and compute a single diff op
--- from the current buffer state. This coalesces rapid edits into one
--- correct op and never requires byte_offset arithmetic against a possibly-
--- stale mirror.
---@param bufnr number
---@param doc table Document instance
function M.attach(bufnr, doc)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf)
      if doc.applying_remote then return end
      if not doc.joined then return end
      if doc._sync_scheduled then return end
      doc._sync_scheduled = true
      vim.schedule(function() M._sync(doc, buf) end)
    end,
  })
end

--- Reconcile buffer content with doc.content via diff; submit ops for any change.
---@param doc table Document instance
---@param bufnr number
function M._sync(doc, bufnr)
  doc._sync_scheduled = false

  if doc.applying_remote then return end
  if not doc.joined then return end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_content = table.concat(lines, '\n')

  if buf_content == doc.content then return end

  local old = doc.content or ''
  local ops = M._diff_ops(old, buf_content)
  doc.content = buf_content

  if #ops > 0 then
    if not doc._undo_busy then M._undo_record(doc, old, buf_content, ops) end
    doc:submit_op(ops)
  end
  require('overleaf.sync').schedule_write(doc)
end

--- Compute a single OT change (one delete + one insert at the same position)
--- from the byte-level diff of old → new. Finds the longest common UTF-8 safe
--- prefix and suffix; everything between is the change.
---@param old string
---@param new string
---@return table[] ops list of {p, d?} and/or {p, i?}
function M._diff_ops(old, new)
  if old == new then return {} end

  local olen, nlen = #old, #new

  local prefix = 0
  local min_len = math.min(olen, nlen)
  while prefix < min_len and old:byte(prefix + 1) == new:byte(prefix + 1) do
    prefix = prefix + 1
  end
  -- UTF-8 safety: don't split a multi-byte character. If the next byte after
  -- the matching prefix is a continuation byte (10xxxxxx), back up.
  while prefix > 0 do
    local b = old:byte(prefix + 1)
    if b and b >= 0x80 and b < 0xC0 then
      prefix = prefix - 1
    else
      break
    end
  end

  local suffix = 0
  local max_suffix = math.min(olen - prefix, nlen - prefix)
  while suffix < max_suffix and old:byte(olen - suffix) == new:byte(nlen - suffix) do
    suffix = suffix + 1
  end
  -- UTF-8 safety for suffix: the first byte of the suffix region must not be
  -- a continuation byte.
  while suffix > 0 do
    local b = old:byte(olen - suffix + 1)
    if b and b >= 0x80 and b < 0xC0 then
      suffix = suffix - 1
    else
      break
    end
  end

  local deleted = old:sub(prefix + 1, olen - suffix)
  local inserted = new:sub(prefix + 1, nlen - suffix)

  local char_p = ot.byte_to_char(old, prefix)

  local ops = {}
  if #deleted > 0 then table.insert(ops, { p = char_p, d = deleted }) end
  if #inserted > 0 then table.insert(ops, { p = char_p, i = inserted }) end
  return ops
end

--- Apply remote OT operations to a Neovim buffer.
--- Runs synchronously: callers (bridge event handlers, on_remote_op) are
--- already in non-fast-event context. Synchronous application keeps
--- doc.content and the buffer aligned, so the deferred sync diff cannot
--- observe an intermediate "doc.content has remote, buffer doesn't" state.
---@param doc table Document instance
---@param ops table[] list of {p, i?, d?}
function M.apply_remote(doc, ops)
  if not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then return end

  doc.applying_remote = true
  doc._undo_seal = true -- typing after a collaborator's edit starts a new undo step

  local had_error = false

  for _, op in ipairs(ops) do
    local ok, err = pcall(function()
      if op.d then
        local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
        local buf_content = table.concat(all_lines, '\n')
        local byte_p = ot.char_to_byte(buf_content, op.p)
        local start_row, start_col = ot.byte_offset_to_pos(buf_content, byte_p)
        local end_row, end_col = ot.byte_offset_to_pos(buf_content, byte_p + #op.d)
        vim.api.nvim_buf_set_text(doc.bufnr, start_row, start_col, end_row, end_col, { '' })
      end
      if op.i then
        local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
        local buf_content = table.concat(all_lines, '\n')
        local byte_p = ot.char_to_byte(buf_content, op.p)
        local row, col = ot.byte_offset_to_pos(buf_content, byte_p)
        local insert_lines = vim.split(op.i, '\n', { plain = true })
        vim.api.nvim_buf_set_text(doc.bufnr, row, col, row, col, insert_lines)
      end
    end)
    if not ok then
      config.log('error', 'Failed to apply remote op: %s', err)
      had_error = true
      break
    end
  end

  if had_error and doc.content then
    config.log('info', 'Falling back to full buffer replace')
    local new_lines = vim.split(doc.content, '\n', { plain = true })
    pcall(vim.api.nvim_buf_set_lines, doc.bufnr, 0, -1, false, new_lines)
  end

  vim.bo[doc.bufnr].modified = false
  doc.applying_remote = false
end

--- Run chktex linter on buffer content and report via vim.diagnostic
local _lint_ns = vim.api.nvim_create_namespace('overleaf_chktex')
local _lint_timer = nil

function M._run_chktex(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.fn.executable('chktex') ~= 1 then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, '\n')

  local stdout_chunks = {}

  local job_id = vim.fn.jobstart({ 'chktex', '-q', '-f', '%l:%c:%d:%k:%m\n', '--inputfiles=0' }, {
    stdin = 'pipe',
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_chunks = data end
    end,
    on_exit = function(_, _exit_code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end

        local diagnostics = {}
        for _, line in ipairs(stdout_chunks) do
          local lnum, col, len, kind, msg = line:match('^(%d+):(%d+):(%d+):(%w+):(.+)$')
          if lnum then
            local severity = vim.diagnostic.severity.WARN
            if kind == 'Error' then
              severity = vim.diagnostic.severity.ERROR
            elseif kind == 'Message' then
              severity = vim.diagnostic.severity.INFO
            end
            table.insert(diagnostics, {
              lnum = tonumber(lnum) - 1,
              col = tonumber(col) - 1,
              end_col = tonumber(col) - 1 + tonumber(len),
              severity = severity,
              message = msg,
              source = 'chktex',
            })
          end
        end

        vim.diagnostic.set(_lint_ns, bufnr, diagnostics)
      end)
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, content)
    vim.fn.chanclose(job_id, 'stdin')
  end
end

--- Schedule chktex lint with debounce
function M._schedule_lint(bufnr)
  if _lint_timer then _lint_timer:stop() end
  _lint_timer = vim.defer_fn(function() M._run_chktex(bufnr) end, 1000) -- 1 second debounce
end

--- Cleanup buffer resources
---@param doc table Document instance
function M.cleanup(doc)
  if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.api.nvim_buf_delete(doc.bufnr, { force = true }) end
  doc.bufnr = nil
end

return M
