-- Configuration: defaults + user merge. Keymaps are overridable per buffer filetype.
local M = {}

M.defaults = {
  -- Which provider backs the current repo. For now only "github".
  provider = "github",

  -- Default base branch for new PRs / when the remote default can't be detected.
  default_branch = "main",

  -- How many PRs to fetch in list views.
  list_limit = 30,

  -- Date rendering for relative timestamps.
  date = { relative = true },

  -- Per-filetype keymaps. Set any value to false to disable that map.
  -- These are intentionally fugitive-flavored: dense, mnemonic, no leader.
  keymaps = {
    list = {
      open = "<CR>",
      back = "-",
      refresh = "r",
      create = "cc",
      filter = "gf",
      help = "g?",
    },
    pr = {
      open = "<CR>",
      expand = "=",
      back = "-",
      approve = "ca",
      request_changes = "cr",
      comment_review = "cm",
      submit = "cs",
      issue_comment = "ci",
      checkout = "co",
      merge = "gm",
      labels = "gl",
      reviewers = "gv",
      help = "g?",
    },
    diff = {
      comment = "c", -- single comment, posts immediately
      stage = "C", -- stage into pending review
      open_thread = "<CR>",
      reply = "r",
      next_comment = "]r",
      prev_comment = "[r",
      back = "-",
      help = "g?",
    },
    compose = {
      submit = "<C-c><C-c>",
      abort = "<C-c><C-k>",
    },
  },

  -- Highlight/sign glyphs for comment rendering.
  signs = {
    published = "●",
    pending = "○",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
