-- Per-PR in-memory cache. Keyed by PR number. `r` (refresh) busts it.
local M = {}

local prs = {} -- number -> { pr=?, diff=?, threads=?, head_sha=?, fetched_at=? }
local lists = {} -- key -> arbitrary list payload (e.g. dashboard sections)
local inflight = {} -- key -> true (guards against double-fetch)

-- File-blob cache keyed by ref+path. Callers pass immutable commit shas, so a key
-- always maps to one exact file version → safe to persist. Wrapped so a cached
-- empty file ("") is distinguishable from a miss (nil). Optionally disk-backed.
local blobs = {}
local function blob_key(ref, path)
  return tostring(ref) .. "\0" .. path
end

local function disk_enabled()
  return require("gitgood.config").get().cache.disk == true
end
local function disk_dir()
  return vim.fn.stdpath("cache") .. "/gitgood/blobs"
end
local function disk_path(ref, path)
  return disk_dir() .. "/" .. vim.fn.sha256(blob_key(ref, path))
end

function M.get_blob(ref, path)
  local key = blob_key(ref, path)
  local mem = blobs[key]
  if mem then
    return mem
  end
  if disk_enabled() then
    local fp = disk_path(ref, path)
    if vim.fn.filereadable(fp) == 1 then
      local content = table.concat(vim.fn.readfile(fp, "b"), "\n")
      blobs[key] = { content = content } -- promote to memory
      return blobs[key]
    end
  end
  return nil
end

function M.set_blob(ref, path, content)
  blobs[blob_key(ref, path)] = { content = content }
  if disk_enabled() then
    pcall(function()
      vim.fn.mkdir(disk_dir(), "p")
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), disk_path(ref, path), "b")
    end)
  end
end

-- List/dashboard cache (cache-first rendering; `r` busts).
function M.get_list(key)
  return lists[key]
end
function M.set_list(key, payload)
  lists[key] = payload
  return payload
end
function M.bust_list(key)
  if key then
    lists[key] = nil
  else
    lists = {}
  end
end

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
