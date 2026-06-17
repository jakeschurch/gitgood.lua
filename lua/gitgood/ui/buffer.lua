-- Scratch-buffer helpers shared by all gitgood views.
local M = {}

-- line -> item registry, per buffer (cleared on wipe).
local items = {}

-- Open a fresh scratch buffer in the current window.
function M.open(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_set_current_buf(buf)
  items[buf] = {}
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      items[buf] = nil
    end,
  })
  return buf
end

-- Replace buffer contents in one shot; keeps it non-modifiable otherwise.
function M.render(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Associate an item with a 1-based line number.
function M.set_item(buf, lnum, item)
  if items[buf] then
    items[buf][lnum] = item
  end
end

-- Item under the cursor (or a given line).
function M.item_at(buf, lnum)
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  return items[buf] and items[buf][lnum] or nil
end

function M.map(buf, lhs, fn, desc)
  if not lhs or lhs == false then
    return
  end
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

-- Jump to the nearest line (in `dir`) whose item satisfies `pred`. fugitive-style
-- item navigation; works in any gitgood buffer.
function M.move(buf, dir, pred)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(buf)
  local from, to, step = cur + 1, total, 1
  if dir < 0 then
    from, to, step = cur - 1, 1, -1
  end
  for ln = from, to, step do
    local it = M.item_at(buf, ln)
    if it and pred(it) then
      vim.api.nvim_win_set_cursor(0, { ln, 0 })
      return true
    end
  end
  return false
end

-- Close the gitgood view (fugitive `gq`): collapse extra panes, wipe the buffer.
function M.close()
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.cmd, "only")
  end
  pcall(vim.cmd, "bdelete!")
end

-- Bind the universal fugitive verbs every gitgood buffer shares.
function M.common_maps(buf, opts)
  M.map(buf, "q", M.close, "close")
  M.map(buf, "gq", M.close, "close")
  if opts and opts.next_pred then
    M.map(buf, ")", function()
      M.move(buf, 1, opts.next_pred)
    end, "next item")
    M.map(buf, "(", function()
      M.move(buf, -1, opts.next_pred)
    end, "prev item")
  end
end

return M
