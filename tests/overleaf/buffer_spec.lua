local ot = require('overleaf.ot')
local buffer = require('overleaf.buffer')

-- Counter for unique buffer names
local test_counter = 0

-- Helper: wait for the deferred sync (vim.schedule) to fire after a buffer
-- mutation, then return.
local function flush_sync(doc, expected_op_count)
  vim.wait(200, function() return #doc._submitted_ops >= (expected_op_count or 1) end)
end

-- Minimal mock document for testing buffer creation and on_bytes
local function make_doc(content, path)
  test_counter = test_counter + 1
  return {
    doc_id = 'test_doc_' .. test_counter,
    path = path or ('/test_' .. test_counter .. '.tex'),
    bufnr = nil,
    version = 1,
    content = content,
    server_content = content,
    joined = true,
    inflight_op = nil,
    pending_ops = nil,
    applying_remote = false,
    _rejoining = false,
    _flush_timer = nil,
    _submitted_ops = {},
    _rejoin_called = false,

    submit_op = function(self, ops) table.insert(self._submitted_ops, vim.deepcopy(ops)) end,

    check_content = function(self)
      if not self.joined or self._rejoining then return true end
      if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return true end
      if self.applying_remote then return true end
      local buf_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      if buf_content ~= self.content then
        self._rejoin_called = true
        return false
      end
      return true
    end,

    rejoin = function(self) self._rejoin_called = true end,
  }
end

describe('buffer', function()
  describe('create', function()
    it('preserves content after undo-clear for ASCII', function()
      local content = '\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for CJK text', function()
      local content = '日本語のテスト\n二行目'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for emoji', function()
      local content = 'Hello 😀 World\nLine 2 🎉'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves empty document', function()
      local content = ''
      local lines = { '' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves single-line document', function()
      local content = 'just one line'
      local lines = { 'just one line' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('detects divergence via check_content after undo-clear', function()
      local content = 'original content'
      local lines = { 'original content' }
      local doc = make_doc(content)
      -- Force content to differ (simulating Issue #5 garbage)
      doc.content = 'different content'

      local bufnr = buffer.create(doc, lines)

      -- check_content should have detected the mismatch
      assert.is_true(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('on_bytes', function()
    local doc, bufnr

    before_each(function()
      local content = 'Hello World'
      local lines = { 'Hello World' }
      doc = make_doc(content)

      bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      doc.bufnr = bufnr

      buffer.attach(bufnr, doc)
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end)

    it('generates insert op at end', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 11, 0, 11, { '!' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, #ops)
      assert.are.equal(11, ops[1].p)
      assert.are.equal('!', ops[1].i)
      assert.are.equal('Hello World!', doc.content)
    end)

    it('generates insert op at beginning', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(0, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('XHello World', doc.content)
    end)

    it('generates delete op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { '' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal('Hello ', doc.content)
    end)

    it('generates replace op (delete + insert)', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { 'Lua' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal(6, ops[2].p)
      assert.are.equal('Lua', ops[2].i)
      assert.are.equal('Hello Lua', doc.content)
    end)

    it('generates newline insert op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { '', '' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(5, ops[1].p)
      assert.are.equal('\n', ops[1].i)
      assert.are.equal('Hello\n World', doc.content)
    end)

    it('coalesces multiple synchronous edits into one diff op', function()
      -- Two buffer mutations in the same synchronous block share one
      -- scheduled sync, so they produce a single coalesced diff op.
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      vim.api.nvim_buf_set_text(bufnr, 0, 12, 0, 12, { 'Y' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      assert.are.equal('XHello WorldY', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)
    end)

    it('ignores changes when applying_remote is set', function()
      doc.applying_remote = true
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      doc.applying_remote = false
      vim.wait(50, function() return false end)

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)

    it('ignores changes when doc is not joined', function()
      doc.joined = false
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      doc.joined = true
      vim.wait(50, function() return false end)

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)
  end)

  describe('on_bytes multibyte', function()
    it('generates correct char offset for CJK insert', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { 'X' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('日X本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for CJK delete', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 6, { '' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('本', ops[1].d)
      assert.are.equal('日語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for emoji insert', function()
      local content = 'A😀B'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('A😀XB', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for mixed multibyte content', function()
      local content = 'café日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('caféX日本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('maintains content sync across multiline multibyte edits', function()
      local content = '日本語\nHello\n世界'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 1, 0, 1, 5, { '' })
      flush_sync(doc)

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('Hello', ops[1].d)
      assert.are.equal('日本語\n\n世界', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('apply_remote', function()
    it('applies remote insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello Beautiful World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote delete to buffer', function()
      local content = 'Hello Beautiful World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, d = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote CJK insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = '日本' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello日本 World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote multiline insert to buffer', function()
      local content = 'Line 1\nLine 2'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 6, i = '\nNew Line' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Line 1\nNew Line\nLine 2', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Divergence auto-heal
  --
  -- These tests cover what happens when doc.content somehow ends up out of
  -- sync with the buffer (Issue #5/#6, partial on_bytes drops, UltiSnips
  -- snippet expansion firing multi-step edits, etc.). With the deferred
  -- diff-based sync, the next on_bytes triggers a reconcile that produces
  -- a correct single op transforming doc.content → buffer state.
  -- ═══════════════════════════════════════════════════════════════════════

  describe('divergence auto-heal', function()
    -- Helper: create buffer + doc with INTENTIONALLY DIVERGED state
    local function make_diverged(buf_content, doc_content)
      local doc = make_doc(doc_content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(buf_content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)
      return doc, buf
    end

    it('reconciles when buffer and doc.content differ on edit', function()
      -- Buffer: "ABCDE", doc: "XYZWE" (diverged at startup somehow)
      local doc, buf = make_diverged('ABCDE', 'XYZWE')

      -- Delete "BCD" from buffer
      vim.api.nvim_buf_set_text(buf, 0, 1, 0, 4, { '' })
      flush_sync(doc)

      -- After auto-heal, doc.content tracks the buffer
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('AE', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('reconciles when buffer has garbage prefix', function()
      -- Issue #5 aftermath: buffer has garbage, doc does not
      local doc, buf = make_diverged('GAR Hello World', 'Hello World')

      -- Insert 'X' at byte 7 of buffer (after 'GAR Hel')
      vim.api.nvim_buf_set_text(buf, 0, 7, 0, 7, { 'X' })
      flush_sync(doc)

      -- After auto-heal, doc.content tracks the buffer exactly
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('GAR HelXlo World', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('reconciles when buffer has extra content', function()
      local doc, buf = make_diverged('Hello Beautiful World', 'Hello World')

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 15, { '' })
      flush_sync(doc)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('Hello World', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('reconciles replace when both sides differ', function()
      local doc, buf = make_diverged('AABBCC', 'XXYYZZ')

      vim.api.nvim_buf_set_text(buf, 0, 2, 0, 4, { 'DD' })
      flush_sync(doc)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('AADDCC', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('reconciles edit on extra line beyond doc length', function()
      local doc, buf = make_diverged('EXTRA LINE\nHello\nWorld', 'Hello\nWorld')

      vim.api.nvim_buf_set_text(buf, 1, 0, 1, 5, { '' })
      flush_sync(doc)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(buf_content, doc.content)
      assert.are.equal('EXTRA LINE\n\nWorld', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('reconciles CJK divergence between buffer and doc', function()
      local doc, buf = make_diverged('日本語ABC', 'XXXXABC')

      vim.api.nvim_buf_set_text(buf, 0, 9, 0, 9, { 'Z' })
      flush_sync(doc)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('日本語ZABC', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('does not compound across edits — each edit ends in sync', function()
      local doc, buf = make_diverged('XHello World', 'Hello World')

      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { '' })
      flush_sync(doc, 1)
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)

      vim.api.nvim_buf_set_text(buf, 0, 11, 0, 11, { '!' })
      flush_sync(doc, 2)
      buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(buf_lines[1], doc.content)
      assert.are.equal('Hello World!', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('simulates UltiSnips-style rapid multi-step edit and coalesces correctly', function()
      -- UltiSnips snippet expansion: delete trigger then insert body, both in
      -- the same synchronous batch. The deferred sync coalesces these into
      -- ONE correct diff op (rather than chasing fragile per-event byte math).
      local doc = make_doc('foo for bar')
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foo for bar' })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Delete "for" then insert snippet body, simulating UltiSnips
      vim.api.nvim_buf_set_text(buf, 0, 4, 0, 7, { '' })
      vim.api.nvim_buf_set_text(buf, 0, 4, 0, 4, { 'for i in range():', '    pass' })
      flush_sync(doc)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(buf_content, doc.content)
      assert.are.equal('foo for i in range():\n    pass bar', doc.content)
      -- Single coalesced op, not two separate fragile ops
      assert.are.equal(1, #doc._submitted_ops)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── Proves Issue #5 is the root cause of Issue #6 ───────────────

    it('old undo-clear method inserts literal garbage', function()
      local content = '\\documentclass{article}'
      local lines = { content }
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- Old method (the bug): single quotes don't expand \<BS>\<Esc>
      local old_undolevels = vim.bo[buf].undolevels
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_call(buf, function() vim.cmd("exe 'normal a \\<BS>\\<Esc>'") end)
      vim.bo[buf].undolevels = old_undolevels

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      -- Garbage is literally inserted
      assert.are_not.equal(content, buf_content)
      assert.is_truthy(buf_content:find('\\<BS>\\<Esc>', 1, true))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('new undo-clear method preserves content', function()
      local content = '\\documentclass{article}'
      local lines = { content }
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- New method (the fix): API-based, no keystroke interpretation
      local old_undolevels = vim.bo[buf].undolevels
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { ' ' })
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { '' })
      vim.bo[buf].undolevels = old_undolevels

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── End-to-end: even if Issue #5 garbage slips through, auto-heal ──

    it('auto-heals from garbage-prefix divergence on first edit', function()
      local content = 'Hello World'
      local doc = make_doc(content)

      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })

      -- Simulate old undo-clear (inserts garbage)
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_call(buf, function() vim.cmd("exe 'normal a \\<BS>\\<Esc>'") end)
      vim.bo[buf].undolevels = 1000

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are_not.equal(content, buf_content)

      doc.bufnr = buf
      buffer.attach(buf, doc)

      local garbage_len = #buf_content - #content
      vim.api.nvim_buf_set_text(buf, 0, 1 + garbage_len, 0, 1 + garbage_len, { 'X' })
      flush_sync(doc)

      -- After auto-heal: doc.content matches buffer exactly
      local buf_lines2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content2 = table.concat(buf_lines2, '\n')
      assert.are.equal(buf_content2, doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
