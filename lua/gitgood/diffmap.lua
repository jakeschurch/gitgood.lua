-- Map a buffer position in a diff render context to the REST payload GitHub needs
-- for a review comment. CONTEXT-AGNOSTIC: a `region` describes how buffer lines
-- relate to file lines + which side + which commit, so the same code serves a
-- full-file native pane AND an inline-expanded hunk slice in the overview.
local M = {}

-- region = {
--   path, side ("LEFT"|"RIGHT"), commit_id,
--   buf_line_start = 1,        -- first buffer line of the region
--   file_line_start = 1,       -- file line corresponding to buf_line_start
--   commentable = { [file_line]=true } | nil,   -- restrict to in-hunk lines
-- }
function M.new(region)
  region.buf_line_start = region.buf_line_start or 1
  region.file_line_start = region.file_line_start or 1
  return region
end

-- Buffer line (1-based) -> file line for this region.
function M.file_line(region, bufline)
  return region.file_line_start + (bufline - region.buf_line_start)
end

-- Build the REST comment payload for a buffer line. Returns nil if the line is
-- not commentable (outside any hunk) when `commentable` is provided.
function M.payload(region, bufline, body)
  local line = M.file_line(region, bufline)
  if region.commentable and not region.commentable[line] then
    return nil
  end
  return {
    path = region.path,
    side = region.side,
    line = line,
    commit_id = region.commit_id,
    body = body,
  }
end

return M
