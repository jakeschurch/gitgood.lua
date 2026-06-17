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

1. `:GG` (or `:GitGood`) → a **sectioned dashboard**: "Needs my review", "Authored
   by me", "Assigned to me" (configurable). `<CR>` opens a PR; `<Tab>` folds a
   section; `r` refreshes. Results are cached — back-navigation is instant.
2. The PR opens in a **review hub** (fugitive-style): a `key:value` header, then
   `Unviewed`/`Viewed` file sections with a `Review: k/total` counter. Each file shows
   `●`/`○` comment-count badges and folds (`=`) to reveal its hunks + inline threads.
3. `S` marks a file **viewed** — synced to GitHub (same checkbox as the web), moves it
   to the `Viewed` section, and jumps to the next unviewed file.
4. Open a file's full diff: `<CR>` current window · `O` new tab · `o` hsplit · `gO`
   vsplit. On a diff line: `c` single comment now, `C` stage into a review.
5. Submit: `ca` approve · `cr` request changes · `cm` comment · `cs` pick. Composer:
   `<C-c><C-c>` submit, `<C-c><C-k>` abort.

### Keymaps

Consistent across every gitgood buffer (fugitive-style): `<CR>` act/open · `o`/`O`/`gO`
split/tab/vsplit · `=`/`<Tab>` toggle under cursor · `(`/`)` prev/next item · `-` back ·
`q`/`gq` close · `g?` help. All keys resolve from anywhere within an item.

**Dashboard** — `<CR>` open PR (or fold a section header) · `O`/`o`/`gO` open in
tab/split/vsplit · `=`/`<Tab>` fold section · `r` refresh · `cc` create · `-` back

**Review hub** — `<CR>`/`O`/`o`/`gO` open diff (win/tab/split/vsplit) · `=` expand file
inline · `c` comment a diff line (single) · `C` stage into review · *(visual-select lines
then `c`/`C` for a multi-line comment)* · `S` toggle viewed · `]f`/`[f` next/prev file ·
`za`/`<Tab>` fold · `ca`/`cr`/`cm` verdict · `cs` submit · `ci` issue comment · `co`
checkout · `gm` merge · `gl` labels · `gv` reviewers · `-` back

> In the hub `c`/`C` comment the expanded diff line under the cursor. They wait
> briefly for the `c`-prefix verbs (`ca`/`cr`/…) before firing.

**Diff** — `c` single comment · `C` stage to review · `]r`/`[r` next/prev comment · `-` back

All keymaps + the dashboard `sections` are overridable via
`setup({ keymaps = …, sections = … })` (see `lua/gitgood/config.lua`).

## Architecture

The core is transport-blind: it talks to a provider that returns normalized types.
The GitHub provider picks the best wire per operation — **GraphQL → CLI → REST** —
all through `gh` so its auth is reused. See `lua/gitgood/provider/`.
