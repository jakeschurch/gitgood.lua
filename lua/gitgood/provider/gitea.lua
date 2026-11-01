-- Gitea (and Forgejo/Codeberg) provider. Plain REST over `curl`: Gitea has no
-- first-party CLI with enough surface, and no GraphQL. The core never sees any of
-- this.
--
-- Auth: config.gitea.token, else $GITEA_TOKEN. Base URL: config.gitea.url, else
-- derived from the `origin` remote. The token travels to curl over stdin (never
-- argv), so it stays out of `ps`.
--
-- Where Gitea can't match the GitHub-shaped contract, this degrades quietly:
--   * viewed state       — no API; kept in-memory per session
--   * multi-line comments — single-line only; a range collapses to its end line
--   * comment side       — API doesn't report it; threads render on the RIGHT
--   * replies            — native endpoint when present, else a review at the spot
local async = require("gitgood.async")
local model = require("gitgood.model")

local M = {}

local Provider = {}
Provider.__index = Provider

function M.new()
  return setmetatable({}, Provider)
end

-- provider.get() builds a fresh instance per call, so shared state lives here.
local repo_cache = {} -- cwd -> repo identity
local viewed = {} -- number -> { [path] = true }
local comment_loc = {} -- comment id -> { path, line }
local labels_cache = {} -- slug -> { [name] = id }
local replies_supported = nil -- nil unknown | true | false

local PAGE = 50 -- Gitea's default MAX_RESPONSE_ITEMS

local function cfg()
  return require("gitgood.config").get()
end

-- ── transport ──────────────────────────────────────────────────────────────

local function git(args)
  local res = async.system(vim.list_extend({ "git" }, args), { text = true })
  if res.code ~= 0 then
    error("git " .. table.concat(args, " ") .. ": " .. vim.trim(res.stderr or ("exit " .. res.code)))
  end
  return vim.trim(res.stdout or "")
end

-- Pull host / path out of a remote URL. Handles scp-style (git@host:o/r.git),
-- ssh://, and http(s)://. Returns { scheme, host, path } or nil.
local function parse_remote(url)
  if not url or url == "" then
    return nil
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
  if scheme then
    rest = rest:gsub("^[^@/]+@", "") -- drop userinfo
    local hostport, path = rest:match("^([^/]+)/(.+)$")
    if not hostport then
      return nil
    end
    -- an ssh port isn't the web port; an http(s) port is
    local web = scheme == "http" or scheme == "https"
    local host = web and hostport or hostport:gsub(":%d+$", "")
    return { scheme = scheme == "http" and "http" or "https", host = host, path = path }
  end
  local host, path = url:match("^[^@]+@([^:]+):(.+)$")
  if not host then
    host, path = url:match("^([^:/]+):(.+)$")
  end
  if host then
    return { scheme = "https", host = host, path = path }
  end
  return nil
end

-- "owner/repo" from the tail of a remote path (tolerates .git and sub-path installs).
local function owner_name(path)
  path = path:gsub("%.git$", ""):gsub("/+$", "")
  local parts = vim.split(path, "/", { plain = true })
  local name = table.remove(parts)
  local owner = table.remove(parts)
  if owner and name and owner ~= "" and name ~= "" then
    return owner, name
  end
end

local function base_url(remote)
  local url = cfg().gitea.url
  if url and url ~= "" then
    return (url:gsub("/+$", ""))
  end
  if not remote then
    error("gitgood: can't derive Gitea URL — set gitea.url in setup()")
  end
  return remote.scheme .. "://" .. remote.host
end

local function token()
  local t = cfg().gitea.token
  if t and t ~= "" then
    return t
  end
  local env = vim.env.GITEA_TOKEN
  if env and env ~= "" then
    return env
  end
end

-- curl config values are double-quoted with backslash escapes.
local function q(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function query_string(params)
  if not params then
    return ""
  end
  local keys = vim.tbl_keys(params)
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = params[k]
    if v ~= nil then
      out[#out + 1] = vim.uri_encode(k) .. "=" .. vim.uri_encode(tostring(v))
    end
  end
  return #out > 0 and ("?" .. table.concat(out, "&")) or ""
end

-- One HTTP call. opts = { body=table?, params=table?, raw=bool? }.
-- Returns code, text. Never raises on HTTP status — callers decide.
local function http(method, path, opts)
  opts = opts or {}
  local base = base_url(M._remote())
  local lines = {
    "silent",
    "show-error",
    "request = " .. q(method),
    "url = " .. q(base .. "/api/v1" .. path .. query_string(opts.params)),
    "write-out = " .. q("\n%{http_code}"),
    "header = " .. q(opts.raw and "Accept: */*" or "Accept: application/json"),
  }
  local tok = token()
  if tok then
    lines[#lines + 1] = "header = " .. q("Authorization: token " .. tok)
  end
  if opts.body ~= nil then
    lines[#lines + 1] = "header = " .. q("Content-Type: application/json")
    lines[#lines + 1] = "data = " .. q(vim.json.encode(opts.body))
  end
  local res = async.system({ cfg().gitea.curl_cmd, "--config", "-" }, { text = true, stdin = table.concat(lines, "\n") .. "\n" })
  if res.code ~= 0 then
    error(("curl %s %s: %s"):format(method, path, vim.trim(res.stderr or ("exit " .. res.code))))
  end
  local out = res.stdout or ""
  local body, code = out:match("^(.*)\n(%d+)$")
  return tonumber(code) or 0, body or out
end

local function json_decode(str)
  return vim.json.decode(str, { luanil = { object = true, array = true } })
end

local function http_error(method, path, code, text)
  local msg = text
  local ok, data = pcall(json_decode, text)
  if ok and type(data) == "table" and data.message then
    msg = data.message
  end
  if code == 401 and not token() then
    msg = msg .. " (no token: set gitea.token or $GITEA_TOKEN)"
  end
  return ("gitea %s %s: HTTP %d: %s"):format(method, path, code, vim.trim(msg or ""))
end

-- Call and decode; raise on HTTP >= 400. Empty body -> nil.
local function api(method, path, opts)
  local code, text = http(method, path, opts)
  if code >= 400 or code == 0 then
    error(http_error(method, path, code, text))
  end
  if text == "" then
    return nil
  end
  return json_decode(text)
end

-- Walk pages until a short page or `max` items. `params` is cloned per page.
local function paginate(path, params, max)
  local all = {}
  local page = 1
  while true do
    local p = vim.tbl_extend("force", params or {}, { page = page, limit = PAGE })
    local items = api("GET", path, { params = p }) or {}
    vim.list_extend(all, items)
    if #items < PAGE or (max and #all >= max) then
      break
    end
    page = page + 1
  end
  if max and #all > max then
    all = vim.list_slice(all, 1, max)
  end
  return all
end

-- Run `fns` concurrently (each in its own coroutine), at most `width` in flight.
-- Returns results in order; re-raises the first error after everything settles.
local function parallel(fns, width)
  width = width or 8
  local results, first_err = {}, nil
  local i = 1
  while i <= #fns do
    local thunks = {}
    for j = i, math.min(i + width - 1, #fns) do
      thunks[#thunks + 1] = function(resume)
        async.run(function()
          local ok, res = pcall(fns[j])
          if ok then
            results[j] = res
          else
            first_err = first_err or res
          end
          resume(true)
        end, function(e)
          first_err = first_err or e
          resume(true)
        end)
      end
    end
    async.join(thunks)
    i = i + width
  end
  if first_err then
    error(first_err, 0)
  end
  return results
end

-- ── repo identity ──────────────────────────────────────────────────────────

-- The git remote gitgood talks to: "origin" if present, else the first one.
function M._remote()
  local cwd = vim.uv.cwd()
  local cached = repo_cache[cwd]
  if cached and cached.remote then
    return cached.remote
  end
  local name = "origin"
  local ok, url = pcall(git, { "remote", "get-url", name })
  if not ok then
    local first = git({ "remote" }):match("[^\n]+")
    if not first then
      error("gitgood: no git remote to derive the Gitea repo from")
    end
    name = first
    url = git({ "remote", "get-url", name })
  end
  local remote = parse_remote(url)
  if not remote then
    error("gitgood: can't parse remote url: " .. url)
  end
  local owner, repo = owner_name(remote.path)
  remote.owner, remote.name, remote.remote_name = owner, repo, name
  repo_cache[cwd] = repo_cache[cwd] or {}
  repo_cache[cwd].remote = remote
  return remote
end

function Provider:repo()
  local cwd = vim.uv.cwd()
  local cached = repo_cache[cwd]
  if cached and cached.owner then
    return cached
  end
  local remote = M._remote()
  if not (remote.owner and remote.name) then
    error("gitgood: can't determine owner/repo from remote path: " .. remote.path)
  end
  local default_branch = cfg().default_branch
  local ok, data = pcall(api, "GET", ("/repos/%s/%s"):format(remote.owner, remote.name))
  if ok and data and data.default_branch then
    default_branch = data.default_branch
  end
  repo_cache[cwd] = {
    remote = remote,
    owner = remote.owner,
    name = remote.name,
    slug = remote.owner .. "/" .. remote.name,
    default_branch = default_branch,
  }
  return repo_cache[cwd]
end

-- Server version string; also proves URL + reachability (used by :checkhealth).
function Provider:version()
  local data = api("GET", "/version")
  return data and data.version
end

local function rpath(r, suffix)
  return ("/repos/%s/%s%s"):format(r.owner, r.name, suffix)
end

-- ── normalizers ────────────────────────────────────────────────────────────

local FILE_STATUS = { added = "A", modified = "M", deleted = "D", renamed = "R", copied = "R", changed = "M" }

local CHECK_STATE = {
  success = "pass",
  skipped = "pass",
  warning = "pass",
  pending = "pending",
  failure = "fail",
  error = "fail",
}

local function is_draft(pr)
  if pr.draft ~= nil then
    return pr.draft
  end
  local t = pr.title or ""
  return t:match("^%[WIP%]") ~= nil or t:match("^WIP:") ~= nil
end

local function pr_state(pr)
  if pr.merged then
    return "MERGED"
  end
  return pr.state == "closed" and "CLOSED" or "OPEN"
end

-- Combined commit status -> { Check, ... }. Failure to fetch means "no checks".
local function fetch_checks(r, sha)
  if not sha or sha == "" then
    return {}
  end
  local ok, data = pcall(api, "GET", rpath(r, "/commits/" .. sha .. "/status"))
  if not ok or not data then
    return {}
  end
  local checks = {}
  for _, s in ipairs(data.statuses or {}) do
    checks[#checks + 1] = { name = s.context or "check", state = CHECK_STATE[s.status] or "fail" }
  end
  return checks
end

local function normalize_list_item(pr, checks)
  return {
    number = pr.number,
    title = pr.title,
    author = pr.user and pr.user.login or "?",
    is_draft = is_draft(pr),
    state = pr_state(pr),
    head_ref = pr.head and pr.head.ref,
    base_ref = pr.base and pr.base.ref,
    additions = pr.additions,
    deletions = pr.deletions,
    checks = checks or {},
    updated_at = pr.updated_at,
    url = pr.html_url,
  }
end

-- ── search translation ─────────────────────────────────────────────────────

-- The dashboard speaks GitHub search syntax. Translate the qualifiers Gitea can
-- express; anything else is dropped, and leftover words become free-text `q`.
local function parse_search(search)
  local f = { params = {}, text = {} }
  for tok in (search or ""):gmatch("%S+") do
    local key, val = tok:match("^([%w-]+):(.+)$")
    if not key then
      f.text[#f.text + 1] = tok
    elseif key == "is" then
      if val == "open" or val == "closed" then
        f.params.state = val
      elseif val == "merged" then
        f.params.state, f.merged = "closed", true
      end
    elseif val == "@me" then
      if key == "review-requested" then
        f.params.review_requested = true
      elseif key == "reviewed-by" then
        f.params.reviewed = true
      elseif key == "author" then
        f.params.created = true
      elseif key == "assignee" then
        f.params.assigned = true
      elseif key == "mentions" then
        f.params.mentioned = true
      end
    elseif key == "author" then
      f.params.created_by = val
    end
    -- other qualifiers (label:, base:, draft:, ...) have no search-endpoint equivalent
  end
  if #f.text > 0 then
    f.params.q = table.concat(f.text, " ")
  end
  return f
end

-- ── reads ──────────────────────────────────────────────────────────────────

function Provider:list_prs(opts)
  opts = opts or {}
  local r = self:repo()
  local limit = opts.limit or cfg().list_limit
  local f = parse_search(opts.search)
  local state = opts.state or f.params.state or "open"
  if state == "merged" then
    state, f.merged = "closed", true
  end
  f.params.state = state

  local prs
  local personal = f.params.review_requested or f.params.reviewed or f.params.created
    or f.params.assigned or f.params.mentioned or f.params.created_by or f.params.q
  if personal then
    -- Cross-repo search: scope to this owner, then filter to this repo client-side
    -- and hydrate each hit (search results lack head/base/additions).
    local params = vim.tbl_extend("force", f.params, { type = "pulls", owner = r.owner })
    local hits = {}
    local page = 1
    while #hits < limit and page <= 10 do
      local p = vim.tbl_extend("force", params, { page = page, limit = PAGE })
      local items = api("GET", "/repos/issues/search", { params = p }) or {}
      for _, it in ipairs(items) do
        if it.repository and it.repository.full_name == r.slug and #hits < limit then
          hits[#hits + 1] = it.number
        end
      end
      if #items < PAGE then
        break
      end
      page = page + 1
    end
    local fns = {}
    for i, n in ipairs(hits) do
      fns[i] = function()
        return api("GET", rpath(r, "/pulls/" .. n))
      end
    end
    prs = parallel(fns)
  else
    prs = paginate(rpath(r, "/pulls"), { state = state, sort = "recentupdate" }, limit)
  end

  if f.merged then
    prs = vim.tbl_filter(function(p)
      return p.merged
    end, prs)
  end

  local fns = {}
  for i, p in ipairs(prs) do
    fns[i] = function()
      return fetch_checks(r, p.head and p.head.sha)
    end
  end
  local checks = parallel(fns)

  local out = {}
  for i, p in ipairs(prs) do
    out[#out + 1] = normalize_list_item(p, checks[i])
  end
  return out
end

-- Latest review per user wins (Gitea returns them oldest-first).
local function reviewers_from(reviews, requested)
  local latest, order = {}, {}
  for _, rv in ipairs(reviews) do
    local who = rv.user and rv.user.login
    if who and (rv.state == "APPROVED" or rv.state == "REQUEST_CHANGES" or rv.state == "COMMENT") and not rv.dismissed then
      if not latest[who] then
        order[#order + 1] = who
      end
      latest[who] = rv.state
    end
  end
  local STATE = { APPROVED = "approved", REQUEST_CHANGES = "changes_requested", COMMENT = "commented" }
  local out, decision = {}, nil
  for _, rr in ipairs(requested or {}) do
    out[#out + 1] = { name = rr.login or rr.name or "?", state = "requested" }
  end
  for _, who in ipairs(order) do
    out[#out + 1] = { name = who, state = STATE[latest[who]] }
    if latest[who] == "REQUEST_CHANGES" then
      decision = "CHANGES_REQUESTED"
    elseif latest[who] == "APPROVED" and decision ~= "CHANGES_REQUESTED" then
      decision = "APPROVED"
    end
  end
  return out, decision
end

function Provider:get_pr(number)
  local r = self:repo()
  local res = parallel({
    function()
      return api("GET", rpath(r, "/pulls/" .. number))
    end,
    function()
      return paginate(rpath(r, "/pulls/" .. number .. "/files"))
    end,
    function()
      return paginate(rpath(r, "/pulls/" .. number .. "/reviews"))
    end,
  })
  local pr, changed, reviews = res[1], res[2], res[3]
  local checks = fetch_checks(r, pr.head and pr.head.sha)

  local seen = viewed[number] or {}
  local files, adds, dels = {}, 0, 0
  for _, f in ipairs(changed) do
    files[#files + 1] = {
      path = f.filename,
      status = FILE_STATUS[f.status] or "M",
      additions = f.additions or 0,
      deletions = f.deletions or 0,
      viewed = seen[f.filename] == true,
    }
    adds = adds + (f.additions or 0)
    dels = dels + (f.deletions or 0)
  end

  local labels = {}
  for _, l in ipairs(pr.labels or {}) do
    labels[#labels + 1] = l.name
  end

  local reviewers, decision = reviewers_from(reviews, pr.requested_reviewers)

  return {
    node_id = number, -- no GraphQL ids here; mark_viewed keys on the number
    number = pr.number,
    title = pr.title,
    body = pr.body,
    state = pr_state(pr),
    is_draft = is_draft(pr),
    author = pr.user and pr.user.login or "?",
    base_ref = pr.base and pr.base.ref,
    head_ref = pr.head and pr.head.ref,
    head_sha = pr.head and pr.head.sha,
    -- merge_base is what the diff is actually against; base.sha is the branch tip
    base_sha = (pr.merge_base ~= "" and pr.merge_base) or (pr.base and pr.base.sha),
    additions = pr.additions or adds,
    deletions = pr.deletions or dels,
    url = pr.html_url,
    labels = labels,
    files = files,
    checks = checks,
    reviewers = reviewers,
    review_decision = decision,
  }
end

function Provider:get_diff(number)
  local r = self:repo()
  local path = rpath(r, "/pulls/" .. number .. ".diff")
  local code, text = http("GET", path, { raw = true })
  if code >= 400 or code == 0 then
    error(http_error("GET", path, code, text))
  end
  return text
end

function Provider:get_threads(number)
  local r = self:repo()
  local reviews = paginate(rpath(r, "/pulls/" .. number .. "/reviews"))
  local fns = {}
  for _, rv in ipairs(reviews) do
    if (rv.comments_count or 0) > 0 then
      fns[#fns + 1] = function()
        return paginate(rpath(r, ("/pulls/%d/reviews/%d/comments"):format(number, rv.id)))
      end
    end
  end
  local batches = parallel(fns)

  -- Gitea has no thread object: comments on the same path+line form one thread.
  local by_key, threads = {}, {}
  local flat = {}
  for _, batch in ipairs(batches) do
    vim.list_extend(flat, batch)
  end
  table.sort(flat, function(a, b)
    if a.created_at ~= b.created_at then
      return (a.created_at or "") < (b.created_at or "")
    end
    return a.id < b.id
  end)
  for _, c in ipairs(flat) do
    local line = (c.position and c.position ~= 0) and c.position or c.original_position
    if line == 0 then
      line = nil
    end
    local key = (c.path or "") .. "\0" .. tostring(line)
    local t = by_key[key]
    if not t then
      t = {
        id = key,
        path = c.path,
        line = line,
        side = model.SIDE.RIGHT,
        is_resolved = c.resolver ~= nil, -- Gitea marks the root comment
        comments = {},
      }
      by_key[key] = t
      threads[#threads + 1] = t
    end
    t.comments[#t.comments + 1] = {
      id = c.id,
      author = c.user and c.user.login or "?",
      body = c.body,
      created_at = c.created_at,
    }
    comment_loc[c.id] = { path = c.path, line = line }
  end
  return threads
end

-- ── writes ─────────────────────────────────────────────────────────────────

-- GitHub-shaped inline comment -> Gitea review comment. `line` is a file line
-- number; side picks which file it numbers.
local function review_comment(c)
  local out = { path = c.path, body = c.body, new_position = 0, old_position = 0 }
  if (c.side or model.SIDE.RIGHT) == model.SIDE.LEFT then
    out.old_position = c.line
  else
    out.new_position = c.line
  end
  return out
end

local EVENT = {
  [model.REVIEW_EVENT.APPROVE] = "APPROVED",
  [model.REVIEW_EVENT.REQUEST_CHANGES] = "REQUEST_CHANGES",
  [model.REVIEW_EVENT.COMMENT] = "COMMENT",
}

function Provider:add_comment(number, c)
  local r = self:repo()
  -- No standalone-comment endpoint: a one-comment review is the immediate form.
  return api("POST", rpath(r, "/pulls/" .. number .. "/reviews"), {
    body = {
      event = "COMMENT",
      commit_id = c.commit_id,
      body = "",
      comments = { review_comment(c) },
    },
  })
end

function Provider:reply_comment(number, comment_id, body)
  local r = self:repo()
  if replies_supported ~= false then
    local path = rpath(r, ("/pulls/%d/comments/%d/replies"):format(number, comment_id))
    local code, text = http("POST", path, { body = { body = body } })
    if code < 400 and code ~= 0 then
      replies_supported = true
      return text ~= "" and json_decode(text) or nil
    end
    if code ~= 404 and code ~= 405 then
      error(http_error("POST", path, code, text))
    end
    -- 404 can mean "no such endpoint" (older Gitea/Forgejo) or "no such comment".
    -- Fall through to the review-at-location form; it raises if the comment is bad.
    if replies_supported == nil and code == 405 then
      replies_supported = false
    end
  end
  local loc = comment_loc[comment_id]
  if not loc then
    self:get_threads(number) -- refills comment_loc
    loc = comment_loc[comment_id]
  end
  if not (loc and loc.line) then
    error("gitea: can't locate comment " .. tostring(comment_id) .. " to reply to")
  end
  return api("POST", rpath(r, "/pulls/" .. number .. "/reviews"), {
    body = {
      event = "COMMENT",
      body = "",
      comments = { review_comment({ path = loc.path, line = loc.line, body = body }) },
    },
  })
end

function Provider:submit_review(number, review)
  local r = self:repo()
  local comments = {}
  for _, c in ipairs(review.comments or {}) do
    comments[#comments + 1] = review_comment(c)
  end
  return api("POST", rpath(r, "/pulls/" .. number .. "/reviews"), {
    body = {
      event = EVENT[review.event] or review.event,
      body = review.body or "",
      comments = comments,
    },
  })
end

function Provider:add_issue_comment(number, body)
  local r = self:repo()
  return api("POST", rpath(r, "/issues/" .. number .. "/comments"), { body = { body = body } })
end

function Provider:create_pr(opts)
  local r = self:repo()
  local head = git({ "rev-parse", "--abbrev-ref", "HEAD" })
  if head == "HEAD" then
    error("gitea: detached HEAD — check out the branch to open a PR from")
  end
  local title = opts.title or head
  if opts.draft and not is_draft({ title = title }) then
    title = "WIP: " .. title -- Gitea's draft marker (configurable, but this is the default)
  end
  local pr = api("POST", rpath(r, "/pulls"), {
    body = { title = title, body = opts.body or "", head = head, base = opts.base or r.default_branch },
  })
  return pr and pr.html_url
end

function Provider:update_pr(number, opts)
  local r = self:repo()
  return api("PATCH", rpath(r, "/pulls/" .. number), { body = { title = opts.title, body = opts.body } })
end

function Provider:merge_pr(number, opts)
  opts = opts or {}
  local r = self:repo()
  -- merge|squash|rebase are valid `do` values as-is.
  return api("POST", rpath(r, "/pulls/" .. number .. "/merge"), {
    body = { ["do"] = opts.method or "merge", delete_branch_after_merge = opts.delete_branch or false },
  })
end

-- name -> id for this repo's labels (org labels included by the server).
local function label_ids(r, fresh)
  if fresh or not labels_cache[r.slug] then
    local map = {}
    for _, l in ipairs(paginate(rpath(r, "/labels"))) do
      map[l.name] = l.id
    end
    labels_cache[r.slug] = map
  end
  return labels_cache[r.slug]
end

local function resolve_labels(r, names)
  local ids = {}
  local map = label_ids(r)
  for _, n in ipairs(names) do
    n = vim.trim(n)
    local id = map[n]
    if not id then
      id = label_ids(r, true)[n] -- label may have been created since we cached
    end
    if not id then
      error("gitea: unknown label '" .. n .. "'")
    end
    ids[#ids + 1] = id
  end
  return ids
end

function Provider:set_labels(number, opts)
  local r = self:repo()
  if opts.add and #opts.add > 0 then
    api("POST", rpath(r, "/issues/" .. number .. "/labels"), { body = { labels = resolve_labels(r, opts.add) } })
  end
  for _, id in ipairs(resolve_labels(r, opts.remove or {})) do
    api("DELETE", rpath(r, ("/issues/%d/labels/%d"):format(number, id)))
  end
end

function Provider:set_reviewers(number, opts)
  local r = self:repo()
  local path = rpath(r, "/pulls/" .. number .. "/requested_reviewers")
  if opts.add and #opts.add > 0 then
    api("POST", path, { body = { reviewers = vim.tbl_map(vim.trim, opts.add) } })
  end
  if opts.remove and #opts.remove > 0 then
    api("DELETE", path, { body = { reviewers = vim.tbl_map(vim.trim, opts.remove) } })
  end
end

-- Convenience used by ui.pr checkout map. Gitea publishes every PR at
-- refs/pull/N/head, which also works for fork PRs.
function Provider:checkout(number)
  local remote = self:repo().remote.remote_name
  git({ "fetch", remote, ("refs/pull/%d/head"):format(number) })
  local branch = "pr-" .. number
  local exists = async.system({ "git", "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, { text = true }).code == 0
  if exists then
    git({ "checkout", branch })
    git({ "merge", "--ff-only", "FETCH_HEAD" })
  else
    git({ "checkout", "-b", branch, "FETCH_HEAD" })
  end
end

-- Viewed-file state. Gitea has no API for it, so it lives for the session only.
function Provider:mark_viewed(number, path)
  viewed[number] = viewed[number] or {}
  viewed[number][path] = true
  return true
end

function Provider:unmark_viewed(number, path)
  if viewed[number] then
    viewed[number][path] = nil
  end
  return true
end

-- File contents at a ref. nil when absent at that ref (added/deleted files).
function Provider:get_file(path, ref)
  local r = self:repo()
  local segs = vim.tbl_map(vim.uri_encode, vim.split(path, "/", { plain = true }))
  local code, text = http("GET", rpath(r, "/raw/" .. table.concat(segs, "/")), { params = { ref = ref }, raw = true })
  if code ~= 200 then
    return nil
  end
  return text
end

-- Exposed for tests.
M._parse_remote = parse_remote
M._owner_name = owner_name
M._parse_search = parse_search

return M
