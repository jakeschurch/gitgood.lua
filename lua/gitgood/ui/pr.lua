-- PR overview view (fugitive status sections).
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local util = require("gitgood.util")
local buffer = require("gitgood.ui.buffer")
local nav = require("gitgood.ui.nav")
local cache = require("gitgood.cache")

local M = {}

local function section(lines, title, count)
  local header = count ~= nil and ("%s (%d)"):format(title, count) or title
  lines[#lines + 1] = ""
  lines[#lines + 1] = " " .. header .. " " .. string.rep("─", math.max(0, 40 - #header))
end

local function render(buf, pr)
  local lines = {}
  local file_lines = {} -- lnum -> file

  local draft = pr.is_draft and " [DRAFT]" or ""
  lines[#lines + 1] = ("gitgood: #%d %s  [%s]%s"):format(pr.number, pr.title, pr.state, draft)
  lines[#lines + 1] = ("  %s  %s → %s"):format(pr.author, pr.head_ref or "?", pr.base_ref or "?")

  section(lines, "Description")
  for _, l in ipairs(vim.split(pr.body and pr.body ~= "" and pr.body or "(no description)", "\n", { plain = true })) do
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
    lines[#lines + 1] = ("   %s %-44s +%d -%d"):format(f.status, f.path, f.additions or 0, f.deletions or 0)
    file_lines[#lines] = f
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " <CR> open diff · = expand · ca approve · cr request · cs submit · gm merge · - back"

  buffer.render(buf, lines)
  for lnum, f in pairs(file_lines) do
    buffer.set_item(buf, lnum, f)
  end
end

local function soon(feature)
  return function()
    vim.notify("gitgood: " .. feature .. " — coming in a later milestone", vim.log.levels.INFO)
  end
end

local function set_keymaps(buf, number)
  local km = config.get().keymaps.pr
  buffer.map(buf, km.open, function()
    local f = buffer.item_at(buf)
    if f then
      require("gitgood.ui.diff").open(number, f.path)
    end
  end, "open file diff")
  buffer.map(buf, km.back, function()
    nav.back()
  end, "back")
  buffer.map(buf, km.checkout, function()
    async.run(function()
      provider.get():checkout(number)
      vim.notify("gitgood: checked out PR #" .. number, vim.log.levels.INFO)
    end)
  end, "checkout")
  -- Stubs for later milestones.
  buffer.map(buf, km.expand, soon("inline diff expand"), "expand")
  buffer.map(buf, km.approve, soon("approve"), "approve")
  buffer.map(buf, km.request_changes, soon("request changes"), "request changes")
  buffer.map(buf, km.comment_review, soon("comment review"), "comment review")
  buffer.map(buf, km.submit, soon("submit review"), "submit")
  buffer.map(buf, km.merge, soon("merge"), "merge")
  buffer.map(buf, km.labels, soon("labels"), "labels")
  buffer.map(buf, km.reviewers, soon("reviewers"), "reviewers")
end

-- Open the overview for PR `number`. Uses cache unless `force`.
function M.open(number, force)
  nav.go(function()
    local buf = buffer.open("gitgood://pr/" .. number, "gitgood-pr")
    buffer.render(buf, { "gitgood: loading PR #" .. number .. "…" })
    set_keymaps(buf, number)
    async.run(function()
      local cached = not force and cache.get(number)
      local pr = cached and cached.pr
      if not pr then
        pr = provider.get():get_pr(number)
        cache.set(number, { pr = pr, head_sha = pr.head_sha })
      end
      render(buf, pr)
    end)
  end)
end

function M.create()
  soon("create PR")()
end

return M
