# diffview.nvim

A GitHub-style unified single-pane diff view over a repository's modified files,
built on top of [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua).

Opening the view filters nvim-tree to git-dirty files and hijacks its open keys
(`l` / `e` / `<CR>`): pressing one on a modified file shows a single-pane
unified diff (working tree vs HEAD) — context lines prefixed with a space,
added with `+`, removed with `-`, each tinted with a full-width background.
Added/removed rows are also marked in the gutter with a vertical-bar sign
taken from gitsigns' config (the same bar on both sides, with gitsigns'
per-side highlight groups), so the view matches the editor's sign column.
Changed words within a line get a brighter tint, tree-sitter highlights are
lifted onto the view, and long runs of unchanged lines collapse into a
`... N unchanged lines ...` placeholder row (no folds).

## Requirements

- Neovim ≥ 0.10
- [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua)
- A tree-sitter parser for the languages you want highlighted
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — the
  gutter signs use its configured text/highlights when present (falls back to
  `+`/`-` with the view's own tints otherwise)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'kuangliu/diffview.nvim',
  dependencies = { 'nvim-tree/nvim-tree.lua' },
  config = function()
    require('diffview').setup()
  end,
}
```

For a local/dev checkout, use `dir` instead of a URL:

```lua
{
  dir = vim.fn.stdpath('data') .. '/sites/diffview.nvim',
  name = 'diffview',
  dependencies = { 'nvim-tree/nvim-tree.lua' },
  config = function()
    require('diffview').setup()
  end,
}
```

## Usage

| Key                | Action                                                         |
| ------------------ | -------------------------------------------------------------- |
| `<Leader>dv`       | Toggle the view (open / close).                                |
| `:DiffView`        | Toggle the view.                                               |
| `q`                | Close the view and reopen the shown source file.               |
| `<CR>`             | Open the source file at the cursor's line.                     |
| `]]` / `[[`        | Jump to the next / previous change hunk.                       |

When opening, the diff for the file currently being edited is shown first,
falling back to the first modified file (shortest relative path). Inside the
tree, pressing an open key on any modified file switches the view to that
file's diff.

## Highlights

The view defines these highlight groups (re-applied on `ColorScheme`), tuned
for a dark background:

| Group             | Default   | Used for                         |
| ----------------- | --------- | -------------------------------- |
| `DiffViewAdd`     | `#2f5d44` | Added-line background tint       |
| `DiffViewDel`     | `#5d3338` | Removed-line background tint     |
| `DiffViewAddBright` | `#3d7a59` | Changed-word tint on added lines |
| `DiffViewDelBright` | `#7a4448` | Changed-word tint on removed lines |
| `DiffViewHeader`  | `#393f4a` | Header line (filename + counts)  |
| `DiffViewSep`     | `#2e3f56` | Collapsed-context placeholder    |

Override any of them in your colorscheme to recolor the view.

## License

MIT
