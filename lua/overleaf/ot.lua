-- OT (Operational Transform) engine for Overleaf protocol
-- Operations: {p = position (0-based CHARACTER offset), i = "insert text"} / {p, d = "delete text"}
-- All positions are Unicode character offsets, matching the Overleaf server protocol.

local M = {}

--- Count UTF-8 characters in a string
---@param s string UTF-8 encoded string
---@return number character count
function M.utf8_len(s)
  local len = 0
  local i = 1
  local n = #s
  while i <= n do
    local byte = s:byte(i)
    if byte < 0x80 then
      i = i + 1
    elseif byte < 0xE0 then
      i = i + 2
    elseif byte < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    len = len + 1
  end
  return len
end

--- Convert 0-based byte offset to 0-based character offset
---@param s string UTF-8 encoded string
---@param byte_offset number 0-based byte offset
---@return number character offset (0-based)
function M.byte_to_char(s, byte_offset)
  if byte_offset <= 0 then return 0 end
  local chars = 0
  local i = 1
  while i <= byte_offset and i <= #s do
    local byte = s:byte(i)
    if byte < 0x80 then
      i = i + 1
    elseif byte < 0xE0 then
      i = i + 2
    elseif byte < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    chars = chars + 1
  end
  return chars
end

--- Convert 0-based character offset to 0-based byte offset
---@param s string UTF-8 encoded string
---@param char_offset number 0-based character offset
---@return number byte offset (0-based)
function M.char_to_byte(s, char_offset)
  if char_offset <= 0 then return 0 end
  local i = 1
  local n = #s
  local chars = 0
  while i <= n and chars < char_offset do
    local byte = s:byte(i)
    if byte < 0x80 then
      i = i + 1
    elseif byte < 0xE0 then
      i = i + 2
    elseif byte < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    chars = chars + 1
  end
  return i - 1
end

--- Apply a list of operations to a content string
--- Positions in ops are 0-based character offsets.
---@param content string
---@param ops table[] list of {p, i?, d?}
---@return string new content
function M.apply(content, ops)
  for _, op in ipairs(ops) do
    if op.d then
      local byte_p = M.char_to_byte(content, op.p)
      local d_byte_len = #op.d
      local before = content:sub(1, byte_p)
      local after = content:sub(byte_p + d_byte_len + 1)
      content = before .. after
    end
    if op.i then
      local byte_p = M.char_to_byte(content, op.p)
      local before = content:sub(1, byte_p)
      local after = content:sub(byte_p + 1)
      content = before .. op.i .. after
    end
  end
  return content
end

--- Transform component c1 against component c2
--- side: 'left' means c1 wins ties, 'right' means c2 wins ties
--- All positions and lengths are in characters (not bytes).
---@param c1 table single op component {p, i?, d?}
---@param c2 table single op component {p, i?, d?}
---@param side string 'left' or 'right'
---@return table[] list of transformed components (usually 1, sometimes 2 for split deletes)
function M.transform_component(c1, c2, side)
  -- c1 is insert
  if c1.i then
    if c2.i then
      -- Insert vs Insert
      local c2_i_len = M.utf8_len(c2.i)
      if c1.p < c2.p or (c1.p == c2.p and side == 'left') then
        return { { p = c1.p, i = c1.i } }
      else
        return { { p = c1.p + c2_i_len, i = c1.i } }
      end
    elseif c2.d then
      -- Insert vs Delete
      local c2_d_len = M.utf8_len(c2.d)
      if c1.p <= c2.p then
        return { { p = c1.p, i = c1.i } }
      elseif c1.p >= c2.p + c2_d_len then
        return { { p = c1.p - c2_d_len, i = c1.i } }
      else
        -- Insert inside deleted region: move to delete start
        return { { p = c2.p, i = c1.i } }
      end
    end
  end

  -- c1 is delete
  if c1.d then
    local c1_d_len = M.utf8_len(c1.d)
    if c2.i then
      -- Delete vs Insert
      local c2_i_len = M.utf8_len(c2.i)
      local c1_end = c1.p + c1_d_len
      if c2.p >= c1_end then
        -- Insert is after our delete
        return { { p = c1.p, d = c1.d } }
      elseif c2.p <= c1.p then
        -- Insert is before our delete
        return { { p = c1.p + c2_i_len, d = c1.d } }
      else
        -- Insert splits our delete. Components apply sequentially, so after
        -- the first half is deleted the second half starts at c1.p + c2_i_len.
        local split_chars = c2.p - c1.p
        local split_byte = M.char_to_byte(c1.d, split_chars)
        local before = c1.d:sub(1, split_byte)
        local after = c1.d:sub(split_byte + 1)
        return {
          { p = c1.p, d = before },
          { p = c1.p + c2_i_len, d = after },
        }
      end
    elseif c2.d then
      -- Delete vs Delete
      local c2_d_len = M.utf8_len(c2.d)
      local c1_end = c1.p + c1_d_len
      local c2_end = c2.p + c2_d_len

      if c2_end <= c1.p then
        -- c2 is entirely before c1
        return { { p = c1.p - c2_d_len, d = c1.d } }
      elseif c2.p >= c1_end then
        -- c2 is entirely after c1
        return { { p = c1.p, d = c1.d } }
      elseif c2.p <= c1.p and c2_end >= c1_end then
        -- c2 completely contains c1 - nothing left to delete
        return {}
      elseif c2.p <= c1.p and c2_end < c1_end then
        -- c2 overlaps the start of c1
        local overlap_chars = c2_end - c1.p
        local overlap_bytes = M.char_to_byte(c1.d, overlap_chars)
        return { { p = c2.p, d = c1.d:sub(overlap_bytes + 1) } }
      elseif c2.p > c1.p and c2_end >= c1_end then
        -- c2 overlaps the end of c1
        local keep_chars = c2.p - c1.p
        local keep_bytes = M.char_to_byte(c1.d, keep_chars)
        return { { p = c1.p, d = c1.d:sub(1, keep_bytes) } }
      else
        -- c2 is inside c1
        local before_chars = c2.p - c1.p
        local before_bytes = M.char_to_byte(c1.d, before_chars)
        local after_start_chars = c2_end - c1.p
        local after_start_bytes = M.char_to_byte(c1.d, after_start_chars)
        local before = c1.d:sub(1, before_bytes)
        local after = c1.d:sub(after_start_bytes + 1)
        return { { p = c1.p, d = before .. after } }
      end
    end
  end

  -- Comment or unknown op type - pass through
  return { c1 }
end

local function copy(t)
  local r = {}
  for i, v in ipairs(t) do
    r[i] = v
  end
  return r
end

--- Transform two ops (lists of components) against each other.
--- `left` wins ties. Returns left', right' such that
--- apply(apply(base, left), right') == apply(apply(base, right), left')
---@param left table[]
---@param right table[]
---@return table[] left_prime
---@return table[] right_prime
function M.transform_x(left, right)
  if #left == 0 or #right == 0 then return copy(left), copy(right) end

  if #left == 1 and #right == 1 then
    return M.transform_component(left[1], right[1], 'left'),
      M.transform_component(right[1], left[1], 'right')
  end

  if #left > 1 then
    local l1p, rp = M.transform_x({ left[1] }, right)
    local restp, rpp = M.transform_x(vim.list_slice(left, 2), rp)
    for _, c in ipairs(restp) do
      table.insert(l1p, c)
    end
    return l1p, rpp
  end

  -- one left component, several right components
  local lp, r1p = M.transform_x(left, { right[1] })
  local lpp, restp = M.transform_x(lp, vim.list_slice(right, 2))
  for _, c in ipairs(restp) do
    table.insert(r1p, c)
  end
  return lpp, r1p
end

--- Transform a list of ops against another list of ops
---@param ops1 table[] ops to transform
---@param ops2 table[] ops to transform against
---@param side string 'left' (ops1 wins ties) or 'right' (ops2 wins ties)
---@return table[] transformed ops1
function M.transform_ops(ops1, ops2, side)
  if side == 'left' then
    local l = M.transform_x(ops1, ops2)
    return l
  end
  local _, r = M.transform_x(ops2, ops1)
  return r
end

--- Compose two operations into one (op2 applied after op1)
---@param ops1 table[] first operation
---@param ops2 table[] second operation (applied after ops1)
---@return table[] composed operation
function M.compose(ops1, ops2)
  -- Simple composition: just concatenate
  -- This works because ops are position-based and applied sequentially
  local result = {}
  for _, op in ipairs(ops1) do
    table.insert(result, op)
  end
  for _, op in ipairs(ops2) do
    table.insert(result, op)
  end
  return result
end

--- Convert byte offset to (0-indexed row, col) in content string
---@param content string
---@param byte_offset number 0-based byte offset
---@return number row (0-indexed)
---@return number col (0-indexed)
function M.byte_offset_to_pos(content, byte_offset)
  local row = 0
  local last_newline = 0 -- position after last newline (1-indexed in content)

  for i = 1, byte_offset do
    if content:byte(i) == 10 then -- '\n'
      row = row + 1
      last_newline = i
    end
  end

  local col = byte_offset - last_newline
  return row, col
end

--- Convert (0-indexed row, col) to byte offset in content string
---@param content string
---@param row number 0-indexed
---@param col number 0-indexed
---@return number byte offset (0-based)
function M.pos_to_byte_offset(content, row, col)
  local current_row = 0
  local offset = 0

  for i = 1, #content do
    if current_row == row then return offset + col end
    if content:byte(i) == 10 then current_row = current_row + 1 end
    offset = offset + 1
  end

  -- Past end of content, return at the requested position
  return offset + col
end

return M
