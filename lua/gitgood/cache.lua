-- Per-PR in-memory cache. Keyed by PR number. `r` (refresh) busts it.
local M = {}

local prs = {} -- number -> { pr=?, diff=?, threads=?, head_sha=?, fetched_at=? }
local inflight = {} -- key -> true (guards against double-fetch)

function M.get(number)
  return prs[number]
end

function M.set(number, data)
  prs[number] = vim.tbl_extend("force", prs[number] or {}, data)
  return prs[number]
end

function M.bust(number)
  if number then
    prs[number] = nil
  else
    prs = {}
  end
end

-- in-flight guards (key is any string)
function M.is_inflight(key)
  return inflight[key] == true
end
function M.mark_inflight(key)
  inflight[key] = true
end
function M.clear_inflight(key)
  inflight[key] = nil
end

return M
