-- Scratch buffer for writing a comment / reply / review body.
-- Fugitive-style: it's a writable (acwrite) buffer — `:w` / `ZZ` / `:wq` submit,
-- `:q!` aborts. `<C-c><C-c>` / `<C-c><C-k>` still work as shortcuts.
local config = require("gitgood.config")

local M = {}

local seq = 0

-- opts = { title?, initial?, allow_empty?, on_submit(text) }
function M.open(opts)
  local km = config.get().keymaps.compose
  seq = seq + 1
  vim.cmd("botright new")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, buf, "gitgood://compose/" .. seq)
  vim.bo[buf].buftype = "acwrite" -- writable: BufWriteCmd handles the submit
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "gitgood-compose"
  vim.api.nvim_win_set_height(win, 10)
  if opts.title then
    vim.wo[win].winbar = opts.title .. "   (ZZ/:w submit · :q! abort)"
  end
  if opts.initial and opts.initial ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial, "\n", { plain = true }))
  end
  vim.bo[buf].modified = false

  local done = false
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function close_win()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- Submit once. Clears `modified` so the write "succeeds" and ZZ/:wq can quit.
  local function submit()
    if done then
      return
    end
    done = true
    local t = text()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
    end
    if opts.allow_empty or t:match("%S") then
      opts.on_submit(t)
    end
  end
  local function abort()
    done = true -- block any pending BufWriteCmd
    close_win()
  end

  -- `:w` / `ZZ` / `:wq` route here (acwrite buffer).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      submit()
    end,
  })

  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, km.submit, function()
      vim.cmd("stopinsert")
      submit()
      close_win()
    end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set(mode, km.abort, function()
      vim.cmd("stopinsert")
      abort()
    end, { buffer = buf, nowait = true, silent = true })
  end

  vim.cmd("startinsert")
  return buf
end

return M
