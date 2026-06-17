-- PR overview view (fugitive status sections) with `=` inline-diff expansion.
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local util = require("gitgood.util")
local buffer = require("gitgood.ui.buffer")
local comments = require("gitgood.comments")
local diffparse = require("gitgood.diffparse")
local nav = require("gitgood.ui.nav")
local cache = require("gitgood.cache")

local M = {}

-- Per-buffer view state (expanded files, loaded diff/threads). Cleared on wipe.
local state = {}

local function section(lines, title, count)
  local header = count ~= nil and ("%s (%d)"):format(title, count) or title
  lines[#lines + 1] = ""
  lines[#lines + 1] = " " .. header .. " " .. string.rep("─", math.max(0, 40 - #header))
end

-- Append a file's parsed hunks inline; record RIGHT file-line -> buffer line.
local function expand_hunks(lines, file_diff, right_map)
  if not file_diff then
    lines[#lines + 1] = "       (no textual diff)"
    return
  end
  for _, h in ipairs(file_diff.hunks) do
    lines[#lines + 1] = ("     @@ -%d +%d @@"):format(h.old_start, h.new_start)
    for _, l in ipairs(h.lines) do
      lines[#lines + 1] = ("   %s  %s"):format(l.sign, l.text)
      if l.new and l.sign ~= "-" then
        right_map[l.new] = #lines
      end
    end
  end
end

local function render(buf)
  local st = state[buf]
  local pr = st.pr
  local lines, file_lines = {}, {}
  local parsed = st.diff and diffparse.parse(st.diff) or {}
  -- thread -> buffer line, across all expanded files (for the overlay pass)
  local thread_bufline = {}

  local draft = pr.is_draft and " [DRAFT]" or ""
  lines[#lines + 1] = ("gitgood: #%d %s  [%s]%s"):format(pr.number, pr.title, pr.state, draft)
  lines[#lines + 1] = ("  %s  %s → %s"):format(pr.author, pr.head_ref or "?", pr.base_ref or "?")

  section(lines, "Description")
  local body = (pr.body and pr.body ~= "") and pr.body or "(no description)"
  for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
    lines[#lines + 1] = "   " .. l
  end

  if pr.checks and #pr.checks > 0 then
    section(lines, "Checks", #pr.checks)
    local parts = {}
    for _, c in ipairs(pr.checks) do
      parts[#parts + 1] = util.check_glyph(c.state) .. " " .. c.name
    end
    lines[#lines + 1] = "   " .. table.concat(parts, "   ")
  end

  if pr.reviewers and #pr.reviewers > 0 then
    section(lines, "Reviewers", #pr.reviewers)
    for _, r in ipairs(pr.reviewers) do
      lines[#lines + 1] = ("   %-20s %s"):format(r.name, r.state)
    end
  end

  if pr.labels and #pr.labels > 0 then
    section(lines, "Labels")
    lines[#lines + 1] = "   " .. table.concat(pr.labels, ", ")
  end

  section(lines, "Files changed", #pr.files)
  for _, f in ipairs(pr.files) do
    local marker = st.expanded[f.path] and "▾" or "▸"
    lines[#lines + 1] = ("   %s %s %-42s +%d -%d"):format(marker, f.status, f.path, f.additions or 0, f.deletions or 0)
    file_lines[#lines] = f
    if st.expanded[f.path] then
      local right_map = {}
      expand_hunks(lines, parsed[f.path], right_map)
      -- map this file's RIGHT threads to their inline buffer lines
      for _, t in ipairs(st.threads or {}) do
        if t.path == f.path and (t.side or "RIGHT") == "RIGHT" and t.line and right_map[t.line] then
          thread_bufline[t] = right_map[t.line]
        end
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " <CR> open diff · = expand · ca approve · cr request · cs submit · gm merge · - back"

  buffer.render(buf, lines)
  for lnum, f in pairs(file_lines) do
    buffer.set_item(buf, lnum, f)
  end

  -- Overlay comments on inline-expanded hunks (same comments.lua as the diff pane).
  if next(thread_bufline) then
    comments.render(buf, st.threads, "RIGHT", function(t)
      return thread_bufline[t]
    end)
  end
end

local function soon(feature)
  return function()
    vim.notify("gitgood: " .. feature .. " — coming in a later milestone", vim.log.levels.INFO)
  end
end

-- Ensure diff + threads are loaded, then re-render (used by `=`).
local function ensure_diff_and_render(buf, number)
  async.run(function()
    local st = state[buf]
    if not st.diff or not st.threads then
      local p = provider.get()
      local entry = cache.get(number) or {}
      st.diff = entry.diff or p:get_diff(number)
      st.threads = entry.threads or p:get_threads(number)
      cache.set(number, { diff = st.diff, threads = st.threads })
    end
    render(buf)
  end)
end

local function set_keymaps(buf, number)
  local km = config.get().keymaps.pr
  buffer.map(buf, km.open, function()
    local f = buffer.item_at(buf)
    if f then
      require("gitgood.ui.diff").open(number, f.path)
    end
  end, "open file diff")
  buffer.map(buf, km.expand, function()
    local f = buffer.item_at(buf)
    if not f then
      return
    end
    state[buf].expanded[f.path] = not state[buf].expanded[f.path]
    ensure_diff_and_render(buf, number)
  end, "expand inline")
  buffer.map(buf, km.back, function()
    nav.back()
  end, "back")
  buffer.map(buf, km.checkout, function()
    async.run(function()
      provider.get():checkout(number)
      vim.notify("gitgood: checked out PR #" .. number, vim.log.levels.INFO)
    end)
  end, "checkout")
  buffer.map(buf, km.approve, soon("approve"), "approve")
  buffer.map(buf, km.request_changes, soon("request changes"), "request changes")
  buffer.map(buf, km.comment_review, soon("comment review"), "comment review")
  buffer.map(buf, km.submit, soon("submit review"), "submit")
  buffer.map(buf, km.merge, soon("merge"), "merge")
  buffer.map(buf, km.labels, soon("labels"), "labels")
  buffer.map(buf, km.reviewers, soon("reviewers"), "reviewers")
end

function M.open(number, force)
  nav.go(function()
    local buf = buffer.open("gitgood://pr/" .. number, "gitgood-pr")
    buffer.render(buf, { "gitgood: loading PR #" .. number .. "…" })
    state[buf] = { expanded = {}, diff = nil, threads = nil }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        state[buf] = nil
      end,
    })
    set_keymaps(buf, number)
    async.run(function()
      local cached = not force and cache.get(number)
      local pr = cached and cached.pr
      if not pr then
        pr = provider.get():get_pr(number)
        cache.set(number, { pr = pr, head_sha = pr.head_sha })
      end
      state[buf].pr = pr
      render(buf)
    end)
  end)
end

function M.create()
  soon("create PR")()
end

return M
