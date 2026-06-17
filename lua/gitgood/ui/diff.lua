-- Native two-pane diff view (base | head), fugitive-style, with comment overlay.
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local config = require("gitgood.config")
local cache = require("gitgood.cache")
local comments = require("gitgood.comments")
local diffparse = require("gitgood.diffparse")
local diffmap = require("gitgood.diffmap")
local nav = require("gitgood.ui.nav")

local M = {}

local function scratch(name, ft, content)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function file_threads(threads, path)
  local out = {}
  for _, t in ipairs(threads) do
    if t.path == path then
      table.insert(out, t)
    end
  end
  return out
end

local function set_keymaps(buf, ctx)
  local km = config.get().keymaps.diff
  local function map(lhs, fn, desc, mode)
    if lhs then
      vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  map(km.next_comment, function()
    comments.next(ctx.placed)
  end, "next comment")
  map(km.prev_comment, function()
    comments.prev(ctx.placed)
  end, "prev comment")
  map(km.back, function()
    vim.cmd("only")
    nav.back()
  end, "back")
  -- Single comment (c) / stage to review (C).
  map(km.comment, function()
    require("gitgood.review").comment_line(ctx, false)
  end, "single comment")
  map(km.stage, function()
    require("gitgood.review").comment_line(ctx, true)
  end, "stage to review")
  -- Visual-range variants: comment on selected lines. Capture the selection ends
  -- before leaving visual mode.
  local function vrange()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    if a > b then
      a, b = b, a
    end
    vim.api.nvim_input("<Esc>")
    return { start = a, finish = b }
  end
  map(km.comment, function()
    require("gitgood.review").comment_line(ctx, false, vrange())
  end, "single comment (range)", "x")
  map(km.stage, function()
    require("gitgood.review").comment_line(ctx, true, vrange())
  end, "stage to review (range)", "x")
  map(km.help, function()
    vim.notify("gitgood diff  c single comment · C stage to review · ]r/[r nav · - back", vim.log.levels.INFO)
  end, "help")
end

-- Build the two diff panes from already-fetched data (synchronous).
local function build(number, path, pr, diff, threads, base, head)
  local parsed = diffparse.parse(diff)
  local ft = vim.filetype.match({ filename = path }) or ""

  -- head in the current window, base in a left vsplit.
  local head_buf = scratch(("gitgood://pr/%d/%s [HEAD]"):format(number, path), ft, head)
  vim.api.nvim_set_current_buf(head_buf)
  vim.cmd("diffthis")
  vim.cmd("leftabove vsplit")
  local base_buf = scratch(("gitgood://pr/%d/%s [BASE]"):format(number, path), ft, base)
  vim.api.nvim_set_current_buf(base_buf)
  vim.cmd("diffthis")
  vim.cmd("wincmd l") -- focus head pane

  comments.render(base_buf, file_threads(threads, path), "LEFT")

  local region = diffmap.new({
    path = path,
    side = "RIGHT",
    commit_id = pr.head_sha,
    commentable = diffparse.right_lines(parsed[path]),
  })

  local ctx = { number = number, path = path, buf = head_buf, region = region, placed = {} }
  function ctx.redraw()
    if not vim.api.nvim_buf_is_valid(head_buf) then
      return
    end
    local cur = cache.get(number) or {}
    local published = file_threads(cur.threads or {}, path)
    local staged = require("gitgood.review").pending_threads(number, path)
    local all = vim.list_extend(vim.deepcopy(published), staged)
    ctx.placed = comments.render(head_buf, all, "RIGHT")
  end
  ctx.redraw()

  set_keymaps(head_buf, ctx)
  set_keymaps(base_buf, { number = number, path = path, buf = base_buf, placed = {} })
end

function M.open(number, path)
  nav.go(function()
    local entry = cache.get(number) or {}
    local pr, diff, threads = entry.pr, entry.diff, entry.threads
    local cb = pr and cache.get_blob(pr.base_ref, path)
    local ch = pr and cache.get_blob(pr.head_sha, path)

    -- Fully cached: build synchronously, no loading flash.
    if pr and diff and threads and cb and ch then
      build(number, path, pr, diff, threads, cb.content, ch.content)
      return
    end

    -- Miss: loading buffer, then fetch what's missing.
    local loading = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(loading, 0, -1, false, { "gitgood: loading diff " .. path .. "…" })
    vim.bo[loading].bufhidden = "wipe"
    vim.api.nvim_set_current_buf(loading)

    async.run(function()
      local p = provider.get()
      pr = pr or p:get_pr(number)
      diff = diff or p:get_diff(number)
      threads = threads or p:get_threads(number)
      cache.set(number, { pr = pr, diff = diff, threads = threads, head_sha = pr.head_sha })

      local base = cb and cb.content or (p:get_file(path, pr.base_ref) or "")
      local head = ch and ch.content or (p:get_file(path, pr.head_sha) or "")
      cache.set_blob(pr.base_ref, path, base)
      cache.set_blob(pr.head_sha, path, head)

      build(number, path, pr, diff, threads, base, head)
    end)
  end)
end

return M
