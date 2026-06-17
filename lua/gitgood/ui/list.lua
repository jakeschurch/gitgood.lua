-- PR list view (fugitive status-buffer analog).
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local model = require("gitgood.model")
local util = require("gitgood.util")
local buffer = require("gitgood.ui.buffer")
local nav = require("gitgood.ui.nav")

local M = {}

local function render(buf, prs)
  local p = provider.get()
  local ok_repo, repo = pcall(function()
    return p:repo()
  end)
  local slug = ok_repo and repo.slug or "?"

  local lines = { "gitgood: " .. slug, "" }
  local line_items = {} -- lnum -> pr

  lines[#lines + 1] = (" Open pull requests (%d)"):format(#prs)
  for _, pr in ipairs(prs) do
    local glyph = util.check_glyph(model.checks_summary(pr.checks))
    local flag = pr.is_draft and "● draft" or (pr.review_decision == "CHANGES_REQUESTED" and "✗ changes" or "")
    local line = ("   #%-5d %-44s %-12s %s checks  +%d -%d"):format(
      pr.number,
      (pr.title or ""):sub(1, 44),
      flag,
      glyph,
      pr.additions or 0,
      pr.deletions or 0
    )
    lines[#lines + 1] = line
    line_items[#lines] = pr
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " g? help · <CR> open · r refresh · cc create"

  buffer.render(buf, lines)
  for lnum, pr in pairs(line_items) do
    buffer.set_item(buf, lnum, pr)
  end
end

local function set_keymaps(buf)
  local km = config.get().keymaps.list
  buffer.map(buf, km.open, function()
    local pr = buffer.item_at(buf)
    if pr then
      require("gitgood.ui.pr").open(pr.number)
    end
  end, "open PR")
  buffer.map(buf, km.refresh, function()
    M.open()
  end, "refresh")
  buffer.map(buf, km.create, function()
    require("gitgood.ui.pr").create()
  end, "create PR")
  buffer.map(buf, km.back, function()
    nav.back()
  end, "back")
  buffer.map(buf, km.help, function()
    M.help()
  end, "help")
end

-- Open (or refresh) the PR list as the navigation root.
function M.open(opts)
  nav.reset(function()
    local buf = buffer.open("gitgood://prs", "gitgood-list")
    buffer.render(buf, { "gitgood: loading pull requests…" })
    set_keymaps(buf)
    async.run(function()
      local p = provider.get()
      local prs = p:list_prs(opts)
      render(buf, prs)
    end)
  end)
end

function M.help()
  local km = config.get().keymaps.list
  vim.notify(
    ("gitgood list\n  %s open  %s refresh  %s create  %s back"):format(
      km.open, km.refresh, km.create, km.back
    ),
    vim.log.levels.INFO
  )
end

return M
