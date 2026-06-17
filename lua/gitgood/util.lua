local M = {}

-- Local UTC offset in seconds (handles DST for "now").
local function utc_offset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- "2h ago" style relative time from an ISO-8601 UTC timestamp.
function M.relative(iso)
  if not iso or iso == "" then
    return ""
  end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return iso
  end
  local epoch = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }) - utc_offset()
  local diff = os.difftime(os.time(), epoch)
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return ("%dm ago"):format(math.floor(diff / 60))
  elseif diff < 86400 then
    return ("%dh ago"):format(math.floor(diff / 3600))
  elseif diff < 86400 * 30 then
    return ("%dd ago"):format(math.floor(diff / 86400))
  else
    return ("%s-%s-%s"):format(y, mo, d)
  end
end

-- Glyph for a rolled-up check summary.
function M.check_glyph(summary)
  return ({ pass = "✓", fail = "✗", pending = "·" })[summary] or " "
end

return M
