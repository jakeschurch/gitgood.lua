-- Scratch buffer for writing a comment / reply / review body.
-- <C-c><C-c> submits, <C-c><C-k> aborts (configurable).
local config = require("gitgood.config")

local M = {}

-- opts = { title?, initial?, allow_empty?, on_submit(text) }
function M.open(opts)
  local km = config.get().keymaps.compose
  vim.cmd("botright new")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, buf, "gitgood://compose")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "gitgood-compose"
  vim.api.nvim_win_set_height(win, 10)
  if opts.title then
    vim.wo[win].winbar = opts.title .. "   (" .. km.submit .. " submit · " .. km.abort .. " abort)"
  end
  if opts.initial and opts.initial ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial, "\n", { plain = true }))
  end

  local done = false
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if submit and (opts.allow_empty or text:match("%S")) then
      opts.on_submit(text)
    end
  end

  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, km.submit, function()
      vim.cmd("stopinsert")
      finish(true)
    end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set(mode, km.abort, function()
      vim.cmd("stopinsert")
      finish(false)
    end, { buffer = buf, nowait = true, silent = true })
  end

  vim.cmd("startinsert")
  return buf
end

return M
