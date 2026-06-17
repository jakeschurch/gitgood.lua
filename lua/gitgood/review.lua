-- Pending-review state + comment posting. Holds an in-memory pending review per PR
-- (staged inline comments), and submits the batch with a verdict.
local async = require("gitgood.async")
local provider = require("gitgood.provider")
local cache = require("gitgood.cache")
local diffmap = require("gitgood.diffmap")
local compose = require("gitgood.ui.compose")

local M = {}

local pending = {} -- number -> { comments = { payload, ... } }

local function bucket(number)
  pending[number] = pending[number] or { comments = {} }
  return pending[number]
end

function M.count(number)
  return pending[number] and #pending[number].comments or 0
end

-- Staged comments for a path, shaped as synthetic threads for the overlay.
function M.pending_threads(number, path)
  local out = {}
  for _, c in ipairs((pending[number] or {}).comments or {}) do
    if c.path == path then
      table.insert(out, {
        path = c.path,
        line = c.line,
        side = c.side,
        pending = true,
        comments = { { author = "you", body = c.body } },
      })
    end
  end
  return out
end

local function refresh_threads(number, ctx)
  async.run(function()
    local th = provider.get():get_threads(number)
    cache.set(number, { threads = th })
    if ctx and ctx.redraw then
      ctx.redraw()
    end
  end)
end

-- Comment on the line(s) under the cursor. `staged`=true stages into the pending
-- review; false posts a single comment immediately. `range` = {start, finish}.
function M.comment_line(ctx, staged, range)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local startline = range and range.start or cur
  local endline = range and range.finish or cur

  compose.open({
    title = ("comment %s:%d%s"):format(ctx.path, endline, staged and " [review]" or " [single]"),
    on_submit = function(body)
      local payload = diffmap.payload(ctx.region, endline, body)
      if not payload then
        return vim.notify("gitgood: line is not part of the diff — can't comment here", vim.log.levels.WARN)
      end
      if range and startline ~= endline then
        payload.start_line = diffmap.file_line(ctx.region, startline)
        payload.start_side = ctx.region.side
      end

      if staged then
        table.insert(bucket(ctx.number).comments, payload)
        if ctx.redraw then
          ctx.redraw()
        end
        vim.notify(("gitgood: staged comment (%d pending)"):format(M.count(ctx.number)), vim.log.levels.INFO)
      else
        async.run(function()
          provider.get():add_comment(ctx.number, payload)
          vim.notify("gitgood: comment posted", vim.log.levels.INFO)
          refresh_threads(ctx.number, ctx)
        end)
      end
    end,
  })
end

-- Comment on a file line / range directly (used by the review hub's inline diff,
-- where we already know path+line, no buffer→line mapping needed).
-- opts = { number, path, head_sha, line, start_line?, side?, staged, on_done? }
function M.comment_inline(opts)
  local side = opts.side or "RIGHT"
  compose.open({
    title = ("comment %s:%s%s%s"):format(
      opts.path,
      opts.start_line and (opts.start_line .. "-") or "",
      opts.line,
      opts.staged and " [review]" or " [single]"
    ),
    on_submit = function(body)
      local payload = { path = opts.path, line = opts.line, side = side, commit_id = opts.head_sha, body = body }
      if opts.start_line and opts.start_line ~= opts.line then
        payload.start_line = opts.start_line
        payload.start_side = side
      end
      if opts.staged then
        table.insert(bucket(opts.number).comments, payload)
        vim.notify(("gitgood: staged comment (%d pending)"):format(M.count(opts.number)), vim.log.levels.INFO)
        if opts.on_done then
          opts.on_done()
        end
      else
        async.run(function()
          provider.get():add_comment(opts.number, payload)
          local th = provider.get():get_threads(opts.number)
          cache.set(opts.number, { threads = th })
          vim.notify("gitgood: comment posted", vim.log.levels.INFO)
          if opts.on_done then
            opts.on_done()
          end
        end)
      end
    end,
  })
end

-- Submit the pending review for `number` with `event` (APPROVE/REQUEST_CHANGES/
-- COMMENT). Opens compose for the review body first.
function M.submit(number, event, on_done)
  local b = pending[number] or { comments = {} }
  local approve = event == "APPROVE"
  compose.open({
    title = ("%s review #%d (%d inline)"):format(event, number, #b.comments),
    allow_empty = approve, -- approvals commonly have no body
    on_submit = function(body)
      async.run(function()
        provider.get():submit_review(number, { event = event, body = body, comments = b.comments })
        pending[number] = nil
        local th = provider.get():get_threads(number)
        cache.set(number, { threads = th })
        vim.notify(("gitgood: %s review submitted"):format(event), vim.log.levels.INFO)
        if on_done then
          on_done()
        end
      end)
    end,
  })
end

-- :GitGood submit — resolve the current PR from the buffer name and pick an event.
function M.submit_current()
  local name = vim.api.nvim_buf_get_name(0)
  local number = tonumber(name:match("gitgood://pr/(%d+)"))
  if not number then
    return vim.notify("gitgood: open a PR first (:GitGood pr <n>)", vim.log.levels.WARN)
  end
  vim.ui.select({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, { prompt = "Submit review as:" }, function(choice)
    if choice then
      M.submit(number, choice)
    end
  end)
end

return M
