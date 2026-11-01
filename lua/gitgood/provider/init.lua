-- Provider registry + interface contract. Core code resolves a provider here and
-- only ever calls the CONTRACT functions — never `gh`/REST directly.
local M = {}

local registry = {}

-- Functions every provider must implement. All are coroutine-style: call them
-- inside async.run(); they yield internally and may run sub-requests in parallel.
M.CONTRACT = {
  "list_prs", -- (opts) -> { PR(list-shape), ... }
  "get_pr", -- (number) -> PR (overview-shape)
  "get_diff", -- (number) -> raw unified diff string
  "get_threads", -- (number) -> { Thread, ... }
  "add_comment", -- (number, {path,line,side,body,commit_id}) single, immediate
  "reply_comment", -- (number, comment_id, body)
  "submit_review", -- (number, {event, body, comments={...}})
  "add_issue_comment", -- (number, body)
  "create_pr", -- (opts)
  "update_pr", -- (number, opts)
  "merge_pr", -- (number, opts)
  "set_labels", -- (number, {add=?, remove=?})
  "set_reviewers", -- (number, {add=?, remove=?})
  "mark_viewed", -- (pr_node_id, path) synced where the forge supports it, else session-local
  "unmark_viewed", -- (pr_node_id, path)
}

function M.register(name, factory)
  registry[name] = factory
end

function M.validate(provider)
  for _, fn in ipairs(M.CONTRACT) do
    if type(provider[fn]) ~= "function" then
      error("gitgood: provider is missing required function '" .. fn .. "'")
    end
  end
  return provider
end

local detected = {} -- cwd -> provider name

-- Pick a provider from the `origin` remote. Synchronous (a short curl probe at
-- most, once per repo) so it's safe to call from or outside a coroutine.
--   github.com                      -> github
--   host == config.gitea.url's host -> gitea
--   host answers GET /api/v1/version -> gitea (Gitea and Forgejo both do)
--   anything else (GHE, no answer)  -> github
function M.detect()
  local cwd = vim.uv.cwd()
  if detected[cwd] then
    return detected[cwd]
  end
  local cfg = require("gitgood.config").get()
  local gitea = require("gitgood.provider.gitea")
  local name = "github"

  local url
  local res = vim.system({ "git", "remote", "get-url", "origin" }, { text = true }):wait()
  if res.code ~= 0 then
    local remotes = vim.system({ "git", "remote" }, { text = true }):wait()
    local first = remotes.code == 0 and (remotes.stdout or ""):match("[^\n]+")
    if first then
      res = vim.system({ "git", "remote", "get-url", first }, { text = true }):wait()
    end
  end
  if res.code == 0 then
    url = vim.trim(res.stdout or "")
  end
  local remote = gitea._parse_remote(url)

  if remote and remote.host ~= "github.com" then
    local base = remote.scheme .. "://" .. remote.host
    local cfg_url = cfg.gitea.url
    if cfg_url and cfg_url ~= "" then
      local cfg_host = cfg_url:match("^%a[%w+.-]*://([^/]+)")
      if cfg_host == remote.host then
        name = "gitea"
      end
      base = cfg_url:gsub("/+$", "")
    end
    if name ~= "gitea" then
      local probe = vim.system({ cfg.gitea.curl_cmd, "-sS", "-m", "3", base .. "/api/v1/version" }, { text = true }):wait()
      if probe.code == 0 then
        local ok, data = pcall(vim.json.decode, probe.stdout or "")
        if ok and type(data) == "table" and type(data.version) == "string" then
          name = "gitea"
        end
      end
    end
  end

  detected[cwd] = name
  return name
end

-- Provider name for this repo: config.provider, with "auto" resolved by detect().
function M.resolve_name(name)
  name = name or require("gitgood.config").get().provider
  if name == "auto" then
    return M.detect()
  end
  return name
end

-- Resolve a provider instance. Defaults to config.provider ("auto" detects).
function M.get(name)
  name = M.resolve_name(name)
  local factory = registry[name]
  if not factory then
    error("gitgood: no provider registered named '" .. tostring(name) .. "'")
  end
  return factory()
end

-- Built-in providers.
M.register("github", function()
  return M.validate(require("gitgood.provider.github").new())
end)

-- Gitea, and API-compatible forks (Forgejo, Codeberg).
M.register("gitea", function()
  return M.validate(require("gitgood.provider.gitea").new())
end)
M.register("forgejo", function()
  return M.validate(require("gitgood.provider.gitea").new())
end)

return M
