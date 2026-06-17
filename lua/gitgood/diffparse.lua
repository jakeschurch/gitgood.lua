-- Parse a unified diff (from `gh pr diff`) into per-file hunks with line numbers.
-- Used for: sign placement on changed lines, and validating which lines are
-- commentable (must be inside a hunk) when posting comments.
local M = {}

-- Returns: { [path] = { path=, hunks = { { old_start, new_start,
--   lines = { { sign=" "|"+"|"-", old=?, new=?, text= }, ... } } } } }
function M.parse(patch)
  local files = {}
  local cur, hunk, old_ln, new_ln
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local newpath = line:match("^%+%+%+ b/(.+)")
    if line:match("^diff %-%-git") then
      cur, hunk = nil, nil
    elseif newpath then
      if newpath == "/dev/null" then
        cur = nil
      else
        cur = { path = newpath, hunks = {} }
        files[newpath] = cur
      end
    elseif line:match("^@@") then
      local o, n = line:match("^@@ %-(%d+)%D.-%+(%d+)")
      old_ln, new_ln = tonumber(o), tonumber(n)
      hunk = { old_start = old_ln, new_start = new_ln, lines = {} }
      if cur then
        table.insert(cur.hunks, hunk)
      end
    elseif hunk and cur then
      local c = line:sub(1, 1)
      if c == "+" then
        table.insert(hunk.lines, { sign = "+", new = new_ln, text = line:sub(2) })
        new_ln = new_ln + 1
      elseif c == "-" then
        table.insert(hunk.lines, { sign = "-", old = old_ln, text = line:sub(2) })
        old_ln = old_ln + 1
      elseif c == " " then
        table.insert(hunk.lines, { sign = " ", old = old_ln, new = new_ln, text = line:sub(2) })
        old_ln, new_ln = old_ln + 1, new_ln + 1
      end
    end
  end
  return files
end

-- Set of RIGHT-side (new) line numbers that are inside a hunk → commentable.
function M.right_lines(file)
  local set = {}
  if not file then
    return set
  end
  for _, h in ipairs(file.hunks) do
    for _, l in ipairs(h.lines) do
      if l.new and l.sign ~= "-" then
        set[l.new] = true
      end
    end
  end
  return set
end

return M
