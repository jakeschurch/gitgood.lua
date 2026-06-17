-- Normalized, provider-agnostic types. Providers must return data in these shapes;
-- the rest of gitgood never sees GitHub/GitLab-specific JSON.
local M = {}

M.REVIEW_EVENT = {
  APPROVE = "APPROVE",
  REQUEST_CHANGES = "REQUEST_CHANGES",
  COMMENT = "COMMENT",
}

M.SIDE = { LEFT = "LEFT", RIGHT = "RIGHT" }

-- Roll a list of per-check states into one summary: "pass" | "fail" | "pending" | nil
function M.checks_summary(checks)
  if not checks or #checks == 0 then
    return nil
  end
  local any_pending = false
  for _, c in ipairs(checks) do
    if c.state == "fail" then
      return "fail"
    elseif c.state == "pending" then
      any_pending = true
    end
  end
  return any_pending and "pending" or "pass"
end

-- Shape reference (documentation; not enforced at runtime):
--
-- PR = {
--   number, title, body, state ("OPEN"|"CLOSED"|"MERGED"), is_draft,
--   author, base_ref, head_ref, head_sha, additions, deletions, url,
--   labels = { string, ... },
--   files = { File, ... },
--   checks = { Check, ... },
--   reviewers = { Reviewer, ... },
--   review_decision ("APPROVED"|"CHANGES_REQUESTED"|"REVIEW_REQUIRED"|nil),
-- }
-- File   = { path, status ("A"|"M"|"D"|"R"), additions, deletions }
-- Check  = { name, state ("pass"|"fail"|"pending") }
-- Reviewer = { name, state ("approved"|"changes_requested"|"requested"|"commented") }
-- Thread = { id, path, line, side, is_resolved, comments = { Comment, ... } }
-- Comment = { id, author, body, created_at }

return M
