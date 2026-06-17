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

-- Resolve a provider instance. Defaults to config.provider.
function M.get(name)
  name = name or require("gitgood.config").get().provider
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

return M
