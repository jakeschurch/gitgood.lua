-- Configuration: defaults + user merge. Keymaps are overridable per buffer filetype.
local M = {}

M.defaults = {
  -- Which provider backs the current repo. For now only "github".
  provider = "github",

  -- The `gh` executable. Default resolves on PATH; the Nix package rewrites this
  -- to an absolute store path so gh travels with the plugin.
  gh_cmd = "gh",

  -- Default base branch for new PRs / when the remote default can't be detected.
  default_branch = "main",

  -- Caching. `disk` persists sha-keyed file blobs under stdpath("cache")/gitgood
  -- so diffs open instantly on a cold start. PR/thread data stays in-memory
  -- (it's mutable). Blobs are keyed by immutable commit shas → never stale.
  cache = { disk = false },

  -- Dashboard sections (the :GG / :GitGood view). Each is a GitHub search query;
  -- order = display order. Override to taste.
  sections = {
    { title = "Needs my review", search = "is:open review-requested:@me" },
    { title = "Authored by me", search = "is:open author:@me" },
    { title = "Assigned to me", search = "is:open assignee:@me" },
  },

  -- How many PRs to fetch in list views.
  list_limit = 30,

  -- Date rendering for relative timestamps.
  date = { relative = true },

  -- Per-filetype keymaps. Set any value to false to disable that map.
  -- These are intentionally fugitive-flavored: dense, mnemonic, no leader.
  keymaps = {
    list = {
      open = "<CR>", -- open PR (or fold the section under cursor)
      open_tab = "O",
      open_split = "o",
      open_vsplit = "gO",
      toggle_fold = "<Tab>",
      back = "-",
      refresh = "r",
      create = "cc",
      filter = "gf",
      help = "g?",
    },
    pr = {
      open = "<CR>", -- open native diff in current window
      open_tab = "O", -- open diff in a new tab
      open_split = "o", -- open diff in a horizontal split
      open_vsplit = "gO", -- open diff in a vertical split
      expand = "=", -- toggle inline hunks+threads under a file
      toggle_fold = "<Tab>", -- fold/unfold section or file under cursor
      toggle_viewed = "S", -- mark file viewed (GitHub-synced) + jump next
      next_file = "]f",
      prev_file = "[f",
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
