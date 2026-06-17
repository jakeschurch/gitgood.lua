-- Review hub (design M3): fugitive key:value header + foldable Unviewed/Viewed
-- sections + per-file fold showing hunks AND inline threads, with comment badges.
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local util = require("gitgood.util")
local buffer = require("gitgood.ui.buffer")
local diffparse = require("gitgood.diffparse")
local nav = require("gitgood.ui.nav")
local cache = require("gitgood.cache")

local M = {}

-- per-buffer view state
local state = {}

local function checks_line(checks)
  if not checks or #checks == 0 then
    return "—"
  end
  local pass, fail, pend = 0, 0, 0
  for _, c in ipairs(checks) do
    if c.state == "pass" then
      pass = pass + 1
    elseif c.state == "fail" then
      fail = fail + 1
    else
      pend = pend + 1
    end
  end
  local parts = {}
  if pass > 0 then
    parts[#parts + 1] = "✓ " .. pass
  end
  if fail > 0 then
    parts[#parts + 1] = "✗ " .. fail
  end
  if pend > 0 then
    parts[#parts + 1] = "· " .. pend
  end
  return table.concat(parts, "  ")
end

local function threads_for(threads, path)
  local out = {}
  for _, t in ipairs(threads or {}) do
    if t.path == path then
      out[#out + 1] = t
    end
  end
  return out
end

-- Emit one file's hunks (+ inline threads) as real buffer lines.
-- Append a file's hunks (+ inline threads). EVERY emitted line is tagged in `items`
-- with the owning file, so =/S/O/o/gO/<CR> work anywhere inside the file's block
-- (not just the file row). Code lines also carry their RIGHT-side `line`.
local function emit_file_diff(lines, items, st, file)
  local parsed = st.parsed or {}
  local fdiff = parsed[file.path]
  if not fdiff then
    lines[#lines + 1] = "       (loading diff…)"
    items[#lines] = { file = file }
    return
  end
  local published = threads_for(st.threads, file.path)
  local pending = require("gitgood.review").pending_threads(st.number, file.path)
  local function emit_threads_at(L)
    for _, t in ipairs(published) do
      if t.line == L then
        for _, c in ipairs(t.comments) do
          local first = (vim.split(c.body or "", "\n", { plain = true }))[1] or ""
          lines[#lines + 1] = ("       ┊ ● %s: %s"):format(c.author, first)
          items[#lines] = { file = file, line = L }
        end
      end
    end
    for _, t in ipairs(pending) do
      if t.line == L then
        local c = t.comments[1] or {}
        local first = (vim.split(c.body or "", "\n", { plain = true }))[1] or ""
        lines[#lines + 1] = ("       ┊ ○ you: %s"):format(first)
        items[#lines] = { file = file, line = L }
      end
    end
  end
  for _, h in ipairs(fdiff.hunks) do
    lines[#lines + 1] = ("     @@ -%d +%d @@"):format(h.old_start, h.new_start)
    items[#lines] = { file = file }
    for _, l in ipairs(h.lines) do
      lines[#lines + 1] = ("     %s %s"):format(l.sign, l.text)
      items[#lines] = { file = file, line = l.new }
      if l.new and l.sign ~= "-" then
        emit_threads_at(l.new)
      end
    end
  end
end

local function file_row(st, file)
  local marker = st.file_expanded[file.path] and "▾" or "▸"
  local published = #threads_for(st.threads, file.path)
  local pending = #require("gitgood.review").pending_threads(st.number, file.path)
  local badges = {}
  if published > 0 then
    badges[#badges + 1] = "●" .. published
  end
  if pending > 0 then
    badges[#badges + 1] = "○" .. pending
  end
  return ("   %s %s %-44s +%d -%d %s"):format(
    marker,
    file.status,
    file.path,
    file.additions or 0,
    file.deletions or 0,
    table.concat(badges, " ")
  )
end

local function render(buf)
  local st = state[buf]
  local pr = st.pr
  local lines, items = {}, {}

  local unviewed, viewed = {}, {}
  for _, f in ipairs(pr.files) do
    if f.viewed then
      viewed[#viewed + 1] = f
    else
      unviewed[#unviewed + 1] = f
    end
  end
  local pending_total = require("gitgood.review").count(st.number)

  -- header (fugitive key:value)
  lines[#lines + 1] = ("Pull:   #%d %s (%s)%s"):format(pr.number, pr.title, pr.state, pr.is_draft and " DRAFT" or "")
  lines[#lines + 1] = ("Head:   %s   Base: %s"):format(pr.head_ref or "?", pr.base_ref or "?")
  lines[#lines + 1] = ("Checks: %s"):format(checks_line(pr.checks))
  lines[#lines + 1] = ("Review: %d/%d viewed · %d pending"):format(#viewed, #pr.files, pending_total)
  if st.desc_open then
    lines[#lines + 1] = "Desc:   ▾"
    items[#lines] = { desc = true }
    local body = (pr.body and pr.body ~= "") and pr.body or "(no description)"
    for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
      lines[#lines + 1] = "        " .. l
    end
  else
    lines[#lines + 1] = "Desc:   ▸ (za to read)"
    items[#lines] = { desc = true }
  end
  lines[#lines + 1] = "Help:   g?"
  lines[#lines + 1] = ""

  st.file_lines = {}
  local function emit_section(key, title, files)
    local collapsed = st.section_fold[key]
    lines[#lines + 1] = ("%s %s (%d)"):format(collapsed and "▸" or "▾", title, #files)
    items[#lines] = { section = key }
    if not collapsed then
      for _, f in ipairs(files) do
        lines[#lines + 1] = file_row(st, f)
        items[#lines] = { file = f }
        st.file_lines[#st.file_lines + 1] = #lines
        if st.file_expanded[f.path] then
          emit_file_diff(lines, items, st, f)
        end
      end
    end
    lines[#lines + 1] = ""
  end
  emit_section("unviewed", "Unviewed", unviewed)
  emit_section("viewed", "Viewed", viewed)

  lines[#lines + 1] =
    " <CR> diff · O tab · o split · = expand · S viewed · ]f/[f file · ca/cr/cm/cs review · - back"

  buffer.render(buf, lines)
  for lnum, it in pairs(items) do
    buffer.set_item(buf, lnum, it)
  end
end

-- Ensure the unified diff is parsed (needed to expand a file's hunks).
local function ensure_diff(buf, cb)
  local st = state[buf]
  if st.parsed then
    return cb()
  end
  async.run(function()
    local entry = cache.get(st.number) or {}
    local diff = entry.diff or provider.get():get_diff(st.number)
    cache.set(st.number, { diff = diff })
    st.parsed = diffparse.parse(diff)
    cb()
  end)
end

local function cursor_item(buf)
  return buffer.item_at(buf)
end

local function open_diff(buf, splitcmd)
  local it = cursor_item(buf)
  if not (it and it.file) then
    return
  end
  if splitcmd then
    vim.cmd(splitcmd)
  end
  require("gitgood.ui.diff").open(state[buf].number, it.file.path)
end

local function jump_next_unviewed(buf)
  local st = state[buf]
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for _, ln in ipairs(st.file_lines) do
    local it = buffer.item_at(buf, ln)
    if it and it.file and not it.file.viewed and ln > cur then
      vim.api.nvim_win_set_cursor(0, { ln, 0 })
      return
    end
  end
  -- wrap to first unviewed
  for _, ln in ipairs(st.file_lines) do
    local it = buffer.item_at(buf, ln)
    if it and it.file and not it.file.viewed then
      vim.api.nvim_win_set_cursor(0, { ln, 0 })
      return
    end
  end
end

local function move_file(buf, dir)
  local st = state[buf]
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, ln in ipairs(st.file_lines) do
      if ln > cur then
        target = ln
        break
      end
    end
  else
    for i = #st.file_lines, 1, -1 do
      if st.file_lines[i] < cur then
        target = st.file_lines[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

local function toggle_viewed(buf)
  local it = cursor_item(buf)
  if not (it and it.file) then
    return
  end
  local st = state[buf]
  local file = it.file
  local want = not file.viewed
  async.run(function()
    local p = provider.get()
    if want then
      p:mark_viewed(st.pr.node_id, file.path)
    else
      p:unmark_viewed(st.pr.node_id, file.path)
    end
    file.viewed = want
    cache.set(st.number, { pr = st.pr })
    render(buf)
    if want then
      jump_next_unviewed(buf)
    end
    vim.notify(("gitgood: %s %s"):format(want and "viewed" or "unviewed", file.path), vim.log.levels.INFO)
  end)
end

local function toggle_under_cursor(buf)
  local it = cursor_item(buf)
  if not it then
    return
  end
  local st = state[buf]
  if it.desc then
    st.desc_open = not st.desc_open
    render(buf)
  elseif it.section then
    st.section_fold[it.section] = not st.section_fold[it.section]
    render(buf)
  elseif it.file then
    M.expand(buf)
  end
end

-- Toggle a file's inline hunk+thread expansion.
function M.expand(buf)
  local it = cursor_item(buf)
  if not (it and it.file) then
    return
  end
  local st = state[buf]
  local path = it.file.path
  st.file_expanded[path] = not st.file_expanded[path]
  if st.file_expanded[path] then
    ensure_diff(buf, function()
      render(buf)
    end)
  else
    render(buf)
  end
end

local function set_keymaps(buf)
  local km = config.get().keymaps.pr
  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  local number = state[buf].number

  map(km.open, function()
    open_diff(buf)
  end, "open diff")
  map(km.open_tab, function()
    open_diff(buf, "tabnew")
  end, "open diff in tab")
  map(km.open_split, function()
    open_diff(buf, "split")
  end, "open diff in split")
  map(km.open_vsplit, function()
    open_diff(buf, "vsplit")
  end, "open diff in vsplit")
  -- =, <Tab>, za all toggle whatever is under the cursor: a file expands its
  -- hunks; a section / Desc folds.
  for _, lhs in ipairs({ km.expand, km.toggle_fold, "za" }) do
    map(lhs, function()
      toggle_under_cursor(buf)
    end, "toggle under cursor")
  end
  map(km.toggle_viewed, function()
    toggle_viewed(buf)
  end, "toggle viewed")
  map("s", function() -- lowercase alias (fugitive muscle memory)
    toggle_viewed(buf)
  end, "toggle viewed")
  map(km.next_file, function()
    move_file(buf, 1)
  end, "next file")
  map(km.prev_file, function()
    move_file(buf, -1)
  end, "prev file")
  map(km.back, function()
    nav.back()
  end, "back")
  map(km.checkout, function()
    async.run(function()
      provider.get():checkout(number)
      vim.notify("gitgood: checked out PR #" .. number, vim.log.levels.INFO)
    end)
  end, "checkout")

  local function submit(event)
    return function()
      require("gitgood.review").submit(number, event, function()
        M.open(number, true)
      end)
    end
  end
  map(km.approve, submit("APPROVE"), "approve")
  map(km.request_changes, submit("REQUEST_CHANGES"), "request changes")
  map(km.comment_review, submit("COMMENT"), "comment review")
  map(km.submit, function()
    require("gitgood.review").submit_current()
  end, "submit")

  local function run_then_refresh(action, msg)
    async.run(function()
      action(provider.get())
      vim.notify("gitgood: " .. msg, vim.log.levels.INFO)
      M.open(number, true)
    end)
  end
  map(km.merge, function()
    vim.ui.select({ "merge", "squash", "rebase" }, { prompt = "Merge method:" }, function(method)
      if method then
        run_then_refresh(function(p)
          p:merge_pr(number, { method = method })
        end, "PR #" .. number .. " merged (" .. method .. ")")
      end
    end)
  end, "merge")
  map(km.labels, function()
    vim.ui.input({ prompt = "Add labels (comma-sep): " }, function(s)
      if s and s ~= "" then
        run_then_refresh(function(p)
          p:set_labels(number, { add = vim.split(s, ",", { trimempty = true }) })
        end, "labels updated")
      end
    end)
  end, "labels")
  map(km.reviewers, function()
    vim.ui.input({ prompt = "Add reviewers (comma-sep): " }, function(s)
      if s and s ~= "" then
        run_then_refresh(function(p)
          p:set_reviewers(number, { add = vim.split(s, ",", { trimempty = true }) })
        end, "reviewers updated")
      end
    end)
  end, "reviewers")
  map(km.issue_comment, function()
    require("gitgood.ui.compose").open({
      title = "comment on #" .. number,
      on_submit = function(body)
        run_then_refresh(function(p)
          p:add_issue_comment(number, body)
        end, "comment posted")
      end,
    })
  end, "issue comment")
  map(km.help, function()
    vim.notify(
      "gitgood review  <CR>/O/o/gO open · = expand · S viewed · ]f/[f file · "
        .. "ca/cr/cm/cs review · ci comment · co checkout · gm merge · gl labels · gv reviewers · - back",
      vim.log.levels.INFO
    )
  end, "help")
end

function M.open(number, force)
  nav.go(function()
    local buf = buffer.open("gitgood://pr/" .. number, "gitgood-pr")
    state[buf] = {
      number = number,
      section_fold = { unviewed = false, viewed = true }, -- viewed collapsed by default
      desc_open = false,
      file_expanded = {},
      file_lines = {},
    }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        state[buf] = nil
      end,
    })
    set_keymaps(buf)

    -- Cache hit: render synchronously, no loading flash (instant on back-nav).
    local entry = not force and cache.get(number)
    if entry and entry.pr and entry.threads then
      state[buf].pr = entry.pr
      state[buf].threads = entry.threads
      render(buf)
      return
    end

    -- Cache miss: show loading once, then fetch.
    buffer.render(buf, { "gitgood: loading PR #" .. number .. "…" })
    async.run(function()
      local p = provider.get()
      local pr = (entry and entry.pr) or p:get_pr(number)
      local threads = (entry and entry.threads) or p:get_threads(number)
      cache.set(number, { pr = pr, threads = threads, head_sha = pr.head_sha })
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      state[buf].pr = pr
      state[buf].threads = threads
      render(buf)
    end)
  end)
end

function M.create()
  vim.ui.input({ prompt = "PR title: " }, function(title)
    if not title or title == "" then
      return
    end
    require("gitgood.ui.compose").open({
      title = "PR body — " .. title,
      allow_empty = true,
      on_submit = function(body)
        async.run(function()
          local out = provider.get():create_pr({ title = title, body = body })
          vim.notify("gitgood: " .. vim.trim(out or "PR created"), vim.log.levels.INFO)
          require("gitgood.ui.list").open({ force = true })
        end)
      end,
    })
  end)
end

return M
