-- Dashboard: sectioned PR list (fugitive status-buffer analog). Cache-first so
-- back-navigation is instant; `r` refetches.
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local model = require("gitgood.model")
local util = require("gitgood.util")
local buffer = require("gitgood.ui.buffer")
local nav = require("gitgood.ui.nav")
local cache = require("gitgood.cache")

local M = {}

local CACHE_KEY = "dashboard"

-- per-buffer fold state: { [section_index] = collapsed_bool }
local folds = {}

local function render(buf, sections)
  local p = provider.get()
  local ok_repo, repo = pcall(function()
    return p:repo()
  end)
  local slug = ok_repo and repo.slug or "?"

  local lines = { "gitgood: " .. slug, "" }
  local line_items = {} -- lnum -> pr
  local fold = folds[buf] or {}

  for idx, sec in ipairs(sections) do
    local collapsed = fold[idx]
    local marker = collapsed and "▸" or "▾"
    lines[#lines + 1] = ("%s %s (%d)"):format(marker, sec.title, #sec.prs)
    local sec_line = #lines
    buffer.set_item(buf, sec_line, { section = idx }) -- so <Tab> knows the section
    if not collapsed then
      if #sec.prs == 0 then
        lines[#lines + 1] = "    (none)"
      end
      for _, pr in ipairs(sec.prs) do
        local glyph = util.check_glyph(model.checks_summary(pr.checks))
        local flag = pr.is_draft and "● draft"
          or (pr.review_decision == "CHANGES_REQUESTED" and "✗ changes" or "")
        lines[#lines + 1] = ("   #%-5d %-44s %-12s %s  +%d -%d"):format(
          pr.number,
          (pr.title or ""):sub(1, 44),
          flag,
          glyph,
          pr.additions or 0,
          pr.deletions or 0
        )
        line_items[#lines] = pr
      end
    end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = " g? help · <CR> open · <Tab> fold · r refresh · cc create"

  buffer.render(buf, lines)
  for lnum, pr in pairs(line_items) do
    buffer.set_item(buf, lnum, pr)
  end
end

local function set_keymaps(buf)
  local km = config.get().keymaps.list
  buffer.map(buf, km.open, function()
    local item = buffer.item_at(buf)
    if item and item.number then
      require("gitgood.ui.pr").open(item.number)
    end
  end, "open PR")
  buffer.map(buf, km.refresh, function()
    M.open({ force = true })
  end, "refresh")
  buffer.map(buf, km.create, function()
    require("gitgood.ui.pr").create()
  end, "create PR")
  buffer.map(buf, km.back, function()
    nav.back()
  end, "back")
  buffer.map(buf, "<Tab>", function()
    local item = buffer.item_at(buf)
    local sec = item and item.section
    if sec then
      folds[buf] = folds[buf] or {}
      folds[buf][sec] = not folds[buf][sec]
      local cached = cache.get_list(CACHE_KEY)
      if cached then
        render(buf, cached)
      end
    end
  end, "toggle fold")
  buffer.map(buf, km.help, function()
    vim.notify("gitgood dashboard  <CR> open · <Tab> fold · r refresh · cc create", vim.log.levels.INFO)
  end, "help")
end

-- Open the dashboard as the navigation root. Cache-first unless opts.force.
function M.open(opts)
  opts = opts or {}
  nav.reset(function()
    local buf = buffer.open("gitgood://dashboard", "gitgood-list")
    folds[buf] = {}
    set_keymaps(buf)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        folds[buf] = nil
      end,
    })

    local cached = not opts.force and cache.get_list(CACHE_KEY)
    if cached then
      render(buf, cached)
      return
    end

    buffer.render(buf, { "gitgood: loading pull requests…" })
    async.run(function()
      local p = provider.get()
      local sections = {}
      for _, sec in ipairs(config.get().sections) do
        local prs = p:list_prs({ search = sec.search })
        sections[#sections + 1] = { title = sec.title, search = sec.search, prs = prs }
      end
      cache.set_list(CACHE_KEY, sections)
      render(buf, sections)
    end)
  end)
end

return M
