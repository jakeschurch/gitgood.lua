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
  local gh = require("gitgood.config").get().gh_cmd
  if vim.fn.executable(gh) ~= 1 then
    vim.health.error("`gh` CLI not found (" .. gh .. ")", {
      "Install GitHub CLI: https://cli.github.com",
    })
    return
  end
  vim.health.ok("`gh` CLI found (" .. gh .. ")")

  -- gh auth status exits non-zero when not logged in.
  local res = vim.system({ gh, "auth", "status" }, { text = true }):wait()
  if res.code == 0 then
    vim.health.ok("`gh` authenticated")
  else
    vim.health.error("`gh` not authenticated", {
      "Run: gh auth login",
      (res.stderr or ""),
    })
  end
end

local function check_gitea()
  local cfg = require("gitgood.config").get()
  local curl = cfg.gitea.curl_cmd
  if vim.fn.executable(curl) ~= 1 then
    vim.health.error("`curl` not found (" .. curl .. ")", { "Install curl, or set gitea.curl_cmd" })
    return
  end
  vim.health.ok("`curl` found (" .. curl .. ")")

  local tok = cfg.gitea.token
  if (not tok or tok == "") and (not vim.env.GITEA_TOKEN or vim.env.GITEA_TOKEN == "") then
    vim.health.warn("no Gitea token", {
      "Set gitea.token in setup(), or export GITEA_TOKEN",
      "Create one under Settings > Applications on your Gitea instance",
      "Public repos can be read without one; writes need it",
    })
  else
    vim.health.ok("Gitea token set")
  end

  -- Resolve the instance and ping /version through the provider's own transport.
  local async = require("gitgood.async")
  local done, ok, msg = false, false, nil
  async.run(function()
    local gitea = require("gitgood.provider.gitea")
    local good, err = pcall(function()
      local p = gitea.new()
      local r = p:repo()
      msg = ("%s (Gitea %s)"):format(r.slug, p:version() or "?")
    end)
    ok, msg, done = good, good and msg or tostring(err), true
  end, function(e)
    ok, msg, done = false, tostring(e), true
  end)
  vim.wait(10000, function()
    return done
  end, 50)
  if not done then
    vim.health.error("timed out reaching the Gitea instance")
  elseif ok then
    vim.health.ok("Gitea repo resolved: " .. msg)
  else
    vim.health.error("could not resolve Gitea repo", { msg })
  end
end

function M.check()
  vim.health.start("gitgood")
  check_nvim()
  local provider = require("gitgood.config").get().provider
  if provider == "gitea" or provider == "forgejo" then
    check_gitea()
  else
    check_gh()
  end
end

return M
