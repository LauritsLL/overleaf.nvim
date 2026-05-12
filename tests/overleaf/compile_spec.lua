local overleaf = require('overleaf')

--- Write `bytes` to a fresh temp file and return its path.
local function tmpfile(bytes)
  local path = vim.fn.tempname()
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
  return path
end

describe('compile', function()
  describe('_pdf_looks_valid', function()
    it('accepts a PDF with the %PDF- header and %%EOF trailer', function()
      local pdf = '%PDF-1.5\n' .. string.rep('x', 4096) .. '\nstartxref\n9\n%%EOF\n'
      assert.is_true(overleaf._pdf_looks_valid(tmpfile(pdf)))
    end)

    it('accepts a tiny but well-formed PDF', function()
      assert.is_true(overleaf._pdf_looks_valid(tmpfile('%PDF-1.4\n1 0 obj<<>>endobj\nstartxref\n9\n%%EOF')))
    end)

    it('rejects a truncated PDF (header present, no %%EOF) — the corrupt-output case', function()
      -- xdvipdfmx aborting mid-write, or a clobbering parallel compile, leaves
      -- exactly this: non-empty, starts with %PDF-, but no trailer.
      local truncated = '%PDF-1.5\n' .. string.rep('x', 8192)
      assert.is_false(overleaf._pdf_looks_valid(tmpfile(truncated)))
    end)

    it('rejects a file that is not a PDF at all', function()
      assert.is_false(overleaf._pdf_looks_valid(tmpfile('not a pdf %%EOF')))
    end)

    it('rejects an empty file', function()
      assert.is_false(overleaf._pdf_looks_valid(tmpfile('')))
    end)

    it('rejects a missing file', function()
      assert.is_false(overleaf._pdf_looks_valid(vim.fn.tempname() .. '-does-not-exist'))
    end)
  end)

  describe('_build_latexmk_cmd', function()
    local saved
    before_each(function() saved = vim.g.vimtex_compiler_latexmk end)
    after_each(function() vim.g.vimtex_compiler_latexmk = saved end)

    local function index_of(list, value)
      for i, v in ipairs(list) do
        if v == value then return i end
      end
    end

    it('always raises the xdvipdfmx output PDF version (fixes truncated PDFs on PDF-1.7 includes)', function()
      vim.g.vimtex_compiler_latexmk = nil
      local cmd = overleaf._build_latexmk_cmd('/tmp/main.tex', false)
      local i = index_of(cmd, '-e')
      assert.is_truthy(i, '-e should be present')
      assert.is_truthy(cmd[i + 1]:match('%-V 7'), 'the -e snippet should bump xdvipdfmx to -V 7')
      assert.are.equal('/tmp/main.tex', cmd[#cmd])
    end)

    it('adds default engine/synctex/interaction flags when VimTeX is unconfigured', function()
      vim.g.vimtex_compiler_latexmk = nil
      local cmd = overleaf._build_latexmk_cmd('/tmp/main.tex', false)
      assert.is_truthy(index_of(cmd, '-pdf'))
      assert.is_truthy(index_of(cmd, '-synctex=1'))
      assert.is_truthy(index_of(cmd, '-interaction=nonstopmode'))
      assert.is_truthy(index_of(cmd, '-file-line-error'))
    end)

    it('honors the user VimTeX engine choice and does not force -pdf', function()
      vim.g.vimtex_compiler_latexmk = { options = { '-xelatex', '-synctex=1', '-interaction=nonstopmode', '-file-line-error' } }
      local cmd = overleaf._build_latexmk_cmd('/tmp/main.tex', false)
      assert.is_truthy(index_of(cmd, '-xelatex'))
      assert.is_nil(index_of(cmd, '-pdf'))
      assert.is_truthy(index_of(cmd, '-e')) -- xdvipdfmx version bump still applied
    end)

    it('passes -g when forcing a rebuild', function()
      vim.g.vimtex_compiler_latexmk = nil
      assert.is_truthy(index_of(overleaf._build_latexmk_cmd('/tmp/main.tex', true), '-g'))
      assert.is_nil(index_of(overleaf._build_latexmk_cmd('/tmp/main.tex', false), '-g'))
    end)
  end)
end)
