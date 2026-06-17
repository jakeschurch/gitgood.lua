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

return M
