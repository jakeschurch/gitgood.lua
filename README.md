# gitgood.lua

A Neovim plugin for reviewing pull requests, with a **vim-fugitive** feel:
dedicated buffers, dense mnemonic keymaps, drill-in/back navigation, native diff,
and inline review comments — all async. GitHub today; a thin provider interface
keeps GitLab and others a drop-in away.

## Requirements

- Neovim **0.10+** (uses `vim.system`)
- [`gh`](https://cli.github.com) CLI, authenticated (`gh auth login`)

Run `:checkhealth gitgood` to verify.

## Install

```lua
-- lazy.nvim
{
  "jakeschurch/gitgood.lua",
  cmd = "GitGood",
  config = function()
    require("gitgood").setup({})
  end,
}
```

## Usage

| Command | Does |
|---------|------|
| `:GitGood` / `:GitGood prs` | open the PR list |
| `:GitGood pr <n>` | open a PR overview |
| `:GitGood create` | create a PR |
| `:GitGood submit` | submit the pending review (pick a verdict) |

### Flow

1. `:GitGood` → PR list. `<CR>` drills into a PR; `-` goes back.
2. In the overview, `<CR>` opens a file's **native two-pane diff**, or `=`
   expands its hunks **inline**. Existing review threads render as virtual lines.
3. On a diff line: `c` posts a **single comment** immediately; `C` **stages** it
   into a pending review (shown with a `○` sign). Works on a visual range too.
4. Submit the batch: `ca` approve · `cr` request changes · `cm` comment · `cs`
   pick. Each opens a composer (`<C-c><C-c>` submit, `<C-c><C-k>` abort).

### Keymaps

**List** — `<CR>` open · `-` back · `r` refresh · `cc` create · `g?` help

**Overview** — `<CR>` open diff · `=` expand · `ca`/`cr`/`cm` approve/request/comment ·
`cs` submit · `ci` issue comment · `co` checkout · `gm` merge · `gl` labels ·
`gv` reviewers · `-` back

**Diff** — `c` single comment · `C` stage to review · `]r`/`[r` next/prev comment · `-` back

All keymaps are overridable via `setup({ keymaps = { ... } })` (see
`lua/gitgood/config.lua`).

## Architecture

The core is transport-blind: it talks to a provider that returns normalized types.
The GitHub provider picks the best wire per operation — **GraphQL → CLI → REST** —
all through `gh` so its auth is reused. See `lua/gitgood/provider/`.

<!-- gitgood live round-trip test line -->
