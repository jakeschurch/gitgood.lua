-- GitHub provider. Transport is chosen per operation (GraphQL > CLI > REST),
-- all via `gh` so its auth token is reused. The core never sees any of this.
local async = require("gitgood.async")
local model = require("gitgood.model")

local M = {}

local Provider = {}
Provider.__index = Provider

function M.new()
  return setmetatable({ _repo = nil }, Provider)
end

-- ── transport helpers ──────────────────────────────────────────────────────

-- The configured `gh` binary (PATH name, or absolute store path under Nix).
local function gh_bin()
  return require("gitgood.config").get().gh_cmd
end

-- Run `gh <args>`, raise on non-zero, return raw stdout.
local function gh(args)
  local cmd = vim.list_extend({ gh_bin() }, args)
  local res = async.system(cmd)
  if res.code ~= 0 then
    error("gh " .. table.concat(args, " ") .. ": " .. (res.stderr or ("exit " .. res.code)))
  end
  return res.stdout
end

-- Decode with luanil so JSON null becomes absent (nil), not vim.NIL (truthy
-- userdata). Lets `x or default` guards work on nullable GraphQL fields.
local function json_decode(str)
  return vim.json.decode(str, { luanil = { object = true, array = true } })
end

local function gh_json(args)
  return json_decode(gh(args))
end

-- `gh api`. If `body` given, send as JSON over stdin (--input -). Returns decoded
-- JSON (or nil for empty responses).
local function gh_api(args, body)
  local cmd = vim.list_extend({ gh_bin(), "api" }, args)
  local opts = { text = true }
  if body ~= nil then
    cmd = vim.list_extend(cmd, { "--input", "-" })
    opts.stdin = vim.json.encode(body)
  end
  local res = async.system(cmd, opts)
  if res.code ~= 0 then
    error("gh api " .. table.concat(args, " ") .. ": " .. (res.stderr or ("exit " .. res.code)))
  end
  if not res.stdout or res.stdout == "" then
    return nil
  end
  return json_decode(res.stdout)
end

-- GraphQL query via `gh api graphql`. vars is a table of name->value passed with -F.
local function gh_graphql(query, vars)
  local args = { "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars or {}) do
    -- -F type-coerces numbers/bools; -f forces string.
    if type(v) == "number" or type(v) == "boolean" then
      table.insert(args, "-F")
      table.insert(args, ("%s=%s"):format(k, tostring(v)))
    else
      table.insert(args, "-f")
      table.insert(args, ("%s=%s"):format(k, v))
    end
  end
  return gh_json(args)
end

-- ── repo identity ──────────────────────────────────────────────────────────

function Provider:repo()
  if self._repo then
    return self._repo
  end
  -- Fast path: explicit GH_REPO override ("[host/]owner/repo"). gh's own
  -- `repo view --json` shells to git and ignores GH_REPO, so resolve it ourselves.
  local fallback_branch = require("gitgood.config").get().default_branch
  local env = vim.env.GH_REPO
  if env and env ~= "" then
    local parts = vim.split(env, "/", { plain = true })
    local name = table.remove(parts)
    local owner = table.remove(parts)
    if owner and name then
      self._repo = {
        owner = owner,
        name = name,
        slug = owner .. "/" .. name,
        default_branch = fallback_branch,
      }
      return self._repo
    end
  end
  local data = gh_json({ "repo", "view", "--json", "owner,name,nameWithOwner,defaultBranchRef" })
  self._repo = {
    owner = data.owner.login,
    name = data.name,
    slug = data.nameWithOwner,
    default_branch = (data.defaultBranchRef and data.defaultBranchRef.name) or fallback_branch,
  }
  return self._repo
end

-- ── normalizers ────────────────────────────────────────────────────────────

local STATUS_MAP = { ADDED = "A", MODIFIED = "M", REMOVED = "D", RENAMED = "R", COPIED = "R" }

-- Summarize a single GraphQL statusCheckRollup context node into a check state.
local function check_state(node)
  if node.__typename == "CheckRun" then
    if node.conclusion == "SUCCESS" or node.conclusion == "NEUTRAL" or node.conclusion == "SKIPPED" then
      return "pass"
    elseif node.conclusion == nil then
      return "pending"
    else
      return "fail"
    end
  else -- StatusContext
    if node.state == "SUCCESS" then
      return "pass"
    elseif node.state == "PENDING" then
      return "pending"
    else
      return "fail"
    end
  end
end

-- Summarize check-run array from `gh pr list` (REST-ish JSON, not GraphQL).
local function checks_from_list(rollup)
  local checks = {}
  for _, c in ipairs(rollup or {}) do
    local state
    local s = c.conclusion or c.state or c.status
    if s == "SUCCESS" or s == "NEUTRAL" or s == "SKIPPED" then
      state = "pass"
    elseif s == nil or s == "PENDING" or s == "IN_PROGRESS" or s == "QUEUED" then
      state = "pending"
    else
      state = "fail"
    end
    table.insert(checks, { name = c.name or c.context or "check", state = state })
  end
  return checks
end

local function normalize_list_item(p)
  return {
    number = p.number,
    title = p.title,
    author = p.author and p.author.login or "?",
    is_draft = p.isDraft,
    state = p.state,
    head_ref = p.headRefName,
    base_ref = p.baseRefName,
    additions = p.additions,
    deletions = p.deletions,
    review_decision = p.reviewDecision ~= "" and p.reviewDecision or nil,
    checks = checks_from_list(p.statusCheckRollup),
    updated_at = p.updatedAt,
    url = p.url,
  }
end

-- ── reads ──────────────────────────────────────────────────────────────────

function Provider:list_prs(opts)
  opts = opts or {}
  local limit = opts.limit or require("gitgood.config").get().list_limit
  local fields = table.concat({
    "number", "title", "author", "isDraft", "state", "headRefName", "baseRefName",
    "additions", "deletions", "reviewDecision", "statusCheckRollup", "updatedAt", "url",
  }, ",")
  local args = { "pr", "list", "--limit", tostring(limit), "--json", fields }
  if opts.state then
    vim.list_extend(args, { "--state", opts.state })
  end
  local raw = gh_json(args)
  local prs = {}
  for _, p in ipairs(raw) do
    table.insert(prs, normalize_list_item(p))
  end
  return prs
end

local PR_QUERY = [[
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      number title body state isDraft url additions deletions
      author{login}
      baseRefName headRefName headRefOid
      labels(first:30){nodes{name}}
      files(first:100){nodes{path additions deletions changeType}}
      reviewRequests(first:30){nodes{requestedReviewer{
        __typename ... on User{login} ... on Team{name}}}}
      latestOpinionatedReviews(first:30){nodes{author{login} state}}
      commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{
        __typename
        ... on CheckRun{name conclusion status}
        ... on StatusContext{context state}
      }}}}}}
    }
  }
}]]

function Provider:get_pr(number)
  local r = self:repo()
  local data = gh_graphql(PR_QUERY, { owner = r.owner, name = r.name, number = number })
  local pr = data.data.repository.pullRequest

  local files = {}
  for _, f in ipairs(pr.files.nodes) do
    table.insert(files, {
      path = f.path,
      status = STATUS_MAP[f.changeType] or "M",
      additions = f.additions,
      deletions = f.deletions,
    })
  end

  local labels = {}
  for _, l in ipairs(pr.labels.nodes) do
    table.insert(labels, l.name)
  end

  local reviewers = {}
  for _, rr in ipairs(pr.reviewRequests.nodes) do
    local who = rr.requestedReviewer or {}
    table.insert(reviewers, { name = who.login or who.name or "?", state = "requested" })
  end
  for _, rv in ipairs(pr.latestOpinionatedReviews.nodes) do
    local st = ({ APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", COMMENTED = "commented" })[rv.state]
    table.insert(reviewers, { name = rv.author and rv.author.login or "?", state = st or "commented" })
  end

  local checks = {}
  local commit_nodes = pr.commits.nodes
  if commit_nodes[1] and commit_nodes[1].commit.statusCheckRollup then
    for _, c in ipairs(commit_nodes[1].commit.statusCheckRollup.contexts.nodes) do
      table.insert(checks, {
        name = c.name or c.context or "check",
        state = check_state(c),
      })
    end
  end

  return {
    number = pr.number,
    title = pr.title,
    body = pr.body,
    state = pr.state,
    is_draft = pr.isDraft,
    author = pr.author and pr.author.login or "?",
    base_ref = pr.baseRefName,
    head_ref = pr.headRefName,
    head_sha = pr.headRefOid,
    additions = pr.additions,
    deletions = pr.deletions,
    url = pr.url,
    labels = labels,
    files = files,
    checks = checks,
    reviewers = reviewers,
  }
end

function Provider:get_diff(number)
  return gh({ "pr", "diff", tostring(number) })
end

local THREADS_QUERY = [[
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){nodes{
        id isResolved
        comments(first:50){nodes{
          databaseId author{login} body createdAt path line originalLine
          diffHunk
        }}
      }}
    }
  }
}]]

function Provider:get_threads(number)
  local r = self:repo()
  local data = gh_graphql(THREADS_QUERY, { owner = r.owner, name = r.name, number = number })
  local threads = {}
  for _, t in ipairs(data.data.repository.pullRequest.reviewThreads.nodes) do
    local first = t.comments.nodes[1] or {}
    local comments = {}
    for _, c in ipairs(t.comments.nodes) do
      table.insert(comments, {
        id = c.databaseId,
        author = c.author and c.author.login or "?",
        body = c.body,
        created_at = c.createdAt,
      })
    end
    table.insert(threads, {
      id = t.id,
      path = first.path,
      line = first.line or first.originalLine,
      side = model.SIDE.RIGHT,
      is_resolved = t.isResolved,
      comments = comments,
    })
  end
  return threads
end

-- ── writes ─────────────────────────────────────────────────────────────────

function Provider:add_comment(number, c)
  local r = self:repo()
  return gh_api(
    { "-X", "POST", ("repos/%s/pulls/%d/comments"):format(r.slug, number) },
    {
      body = c.body,
      commit_id = c.commit_id,
      path = c.path,
      line = c.line,
      side = c.side or model.SIDE.RIGHT,
      start_line = c.start_line,
      start_side = c.start_side,
    }
  )
end

function Provider:reply_comment(number, comment_id, body)
  local r = self:repo()
  return gh_api(
    { "-X", "POST", ("repos/%s/pulls/%d/comments/%d/replies"):format(r.slug, number, comment_id) },
    { body = body }
  )
end

function Provider:submit_review(number, review)
  local r = self:repo()
  return gh_api(
    { "-X", "POST", ("repos/%s/pulls/%d/reviews"):format(r.slug, number) },
    {
      event = review.event,
      body = review.body or "",
      comments = review.comments or {},
    }
  )
end

function Provider:add_issue_comment(number, body)
  return gh({ "pr", "comment", tostring(number), "--body", body })
end

function Provider:create_pr(opts)
  local args = { "pr", "create" }
  if opts.title then
    vim.list_extend(args, { "--title", opts.title })
  end
  if opts.body then
    vim.list_extend(args, { "--body", opts.body })
  end
  vim.list_extend(args, { "--base", opts.base or self:repo().default_branch })
  if opts.draft then
    table.insert(args, "--draft")
  end
  return gh(args)
end

function Provider:update_pr(number, opts)
  local args = { "pr", "edit", tostring(number) }
  if opts.title then
    vim.list_extend(args, { "--title", opts.title })
  end
  if opts.body then
    vim.list_extend(args, { "--body", opts.body })
  end
  return gh(args)
end

function Provider:merge_pr(number, opts)
  opts = opts or {}
  local args = { "pr", "merge", tostring(number) }
  table.insert(args, "--" .. (opts.method or "merge")) -- merge|squash|rebase
  if opts.delete_branch then
    table.insert(args, "--delete-branch")
  end
  return gh(args)
end

function Provider:set_labels(number, opts)
  local args = { "pr", "edit", tostring(number) }
  for _, l in ipairs(opts.add or {}) do
    vim.list_extend(args, { "--add-label", l })
  end
  for _, l in ipairs(opts.remove or {}) do
    vim.list_extend(args, { "--remove-label", l })
  end
  return gh(args)
end

function Provider:set_reviewers(number, opts)
  local args = { "pr", "edit", tostring(number) }
  for _, rv in ipairs(opts.add or {}) do
    vim.list_extend(args, { "--add-reviewer", rv })
  end
  for _, rv in ipairs(opts.remove or {}) do
    vim.list_extend(args, { "--remove-reviewer", rv })
  end
  return gh(args)
end

-- Convenience used by ui.pr checkout map.
function Provider:checkout(number)
  return gh({ "pr", "checkout", tostring(number) })
end

-- File contents at a ref (branch or sha). Returns content string, or nil if the
-- file does not exist at that ref (e.g. added/deleted files).
function Provider:get_file(path, ref)
  local r = self:repo()
  -- NB: passing -f/-F flips `gh api` to POST; keep ref in the query string so this
  -- stays a GET.
  local cmd = { gh_bin(), "api", ("repos/%s/contents/%s?ref=%s"):format(r.slug, path, vim.uri_encode(ref)) }
  local res = async.system(cmd)
  if res.code ~= 0 then
    return nil -- 404 (missing at ref) or binary; caller treats as empty
  end
  local data = json_decode(res.stdout)
  if not data or not data.content then
    return nil
  end
  local b64 = (data.content:gsub("%s", ""))
  return vim.base64.decode(b64)
end

return M
