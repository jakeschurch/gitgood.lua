-- :checkhealth gitgood
local M = {}

local function check_nvim()
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()) .. " (>= 0.10, vim.system available)")
  else
    vim.health.error("Neovim 0.10+ required (gitgood uses vim.system)")
  end
end

local function check_gh()
  if vim.fn.executable("gh") ~= 1 then
    vim.health.error("`gh` CLI not found on PATH", {
      "Install GitHub CLI: https://cli.github.com",
    })
    return
  end
  vim.health.ok("`gh` CLI found")

  -- gh auth status exits non-zero when not logged in.
  local res = vim.system({ "gh", "auth", "status" }, { text = true }):wait()
  if res.code == 0 then
    vim.health.ok("`gh` authenticated")
  else
    vim.health.error("`gh` not authenticated", {
      "Run: gh auth login",
      (res.stderr or ""),
    })
  end
end

function M.check()
  vim.health.start("gitgood")
  check_nvim()
  check_gh()
end

return M
