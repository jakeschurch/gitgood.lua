-- Comment rendering layer. CONTEXT-AGNOSTIC: renders threads as virt_lines + signs
-- into any (bufnr, side) — works the same for a native diff pane OR an inline-
-- expanded hunk region in the overview. Published vs pending get distinct hl.
local config = require("gitgood.config")

local M = {}

local ns = vim.api.nvim_create_namespace("gitgood_comments")

-- Default highlight links (overridable by user colorscheme).
function M.setup_hl()
  local function link(from, to)
    vim.api.nvim_set_hl(0, from, { link = to, default = true })
  end
  link("GitgoodCommentHeader", "Title")
  link("GitgoodCommentBody", "Comment")
  link("GitgoodCommentPending", "WarningMsg")
  link("GitgoodSignPublished", "DiagnosticInfo")
  link("GitgoodSignPending", "DiagnosticWarn")
end

local function thread_virt_lines(thread)
  local signs = config.get().signs
  local pending = thread.pending
  local label_hl = pending and "GitgoodCommentPending" or "GitgoodCommentHeader"
  local glyph = pending and signs.pending or signs.published
  local virt = {}
  for _, c in ipairs(thread.comments) do
    local tag = pending and " (PENDING review)" or (thread.is_resolved and " (resolved)" or "")
    table.insert(virt, { { ("  %s %s%s"):format(glyph, c.author, tag), label_hl } })
    for _, bl in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
      table.insert(virt, { { "    │ " .. bl, "GitgoodCommentBody" } })
    end
  end
  return virt
end

-- Render all threads for `side` into `buf`. `line_of(thread)` maps a thread to a
-- 1-based buffer line (lets callers handle full-file vs sliced/expanded regions).
-- Returns sorted list of buffer lines that carry a comment (for ]r/[r nav).
function M.render(buf, threads, side, line_of)
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  local signs = config.get().signs
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local placed = {}
  local total = vim.api.nvim_buf_line_count(buf)
  for _, t in ipairs(threads) do
    if (t.side or "RIGHT") == side then
      local lnum = line_of and line_of(t) or t.line
      if lnum and lnum >= 1 and lnum <= total then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
          virt_lines = thread_virt_lines(t),
          sign_text = t.pending and signs.pending or signs.published,
          sign_hl_group = t.pending and "GitgoodSignPending" or "GitgoodSignPublished",
        })
        table.insert(placed, lnum)
      end
    end
  end
  table.sort(placed)
  return placed
end

-- Jump helpers for ]r / [r. `placed` is the sorted list from render().
function M.next(placed)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for _, l in ipairs(placed) do
    if l > cur then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
  end
end

function M.prev(placed)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for i = #placed, 1, -1 do
    if placed[i] < cur then
      vim.api.nvim_win_set_cursor(0, { placed[i], 0 })
      return
    end
  end
end

M.setup_hl()

return M
