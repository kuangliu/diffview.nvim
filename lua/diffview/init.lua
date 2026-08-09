-- GitHub-style unified diff view over a repo's modified files.
--
--   <Leader>dv / :DiffView   Toggle the view. When opening, nvim-tree is
--                            filtered to git-dirty files and its open keys
--                            (l / e / <CR>) are hijacked so pressing them on a
--                            modified file shows a single-pane unified diff
--                            (working tree vs HEAD). The diff for the file
--                            currently being edited is shown first, falling
--                            back to the first modified file.
--   q                        Close the view and reopen the shown source file.
--   <CR>                     Open the source file at the cursor's line.
--   ]] / [[                  Jump to the next / previous change hunk.
--   dd                        Revert the change on the cursor line (delete an
--                             added line / restore a removed one), then jump
--                             to the next change.
--   u                         Undo the last revert and jump back to its line.
--
-- The diff is one pane: context lines are prefixed with a space, added lines
-- with `+` and removed with `-`, each tinted with a full-width background.
-- Added/removed rows are also marked in the gutter with a vertical-bar sign
-- taken from gitsigns' config (the same bar on both sides, gitsigns'
-- highlights), so the view matches the editor's sign column. Changed words
-- within a line get a brighter tint, and tree-sitter highlights are lifted
-- onto the view. Long runs of unchanged lines collapse into a
-- `... N unchanged lines ...` placeholder row (no folds).

local M = {}

-- module-local upvalues
local api ---@type nvim_tree.api
local ns = vim.api.nvim_create_namespace('diffview')
local ts_ns = vim.api.nvim_create_namespace('diffview_ts')

-- Unchanged context lines kept visible on each side of a change. Longer runs
-- have their middle replaced by a placeholder row.
local KEEP = 8

local OPEN_KEYS = { 'l', 'e', '<CR>' }

-- Transient state, all cleared on close / on a failed open.
local state = {
  active = false,
  toplevel = nil,
  modified = {},        -- set of absolute paths with uncommitted changes
  saved_clean = nil,    -- prior value of nvim-tree's git_clean filter
  saved_keymaps = {},   -- [bufnr] = { [key] = keymap_dict }
  buffers = {},         -- view bufnrs currently alive
}

--------------------------------------------------------------------------
-- git helpers
--------------------------------------------------------------------------
local function git_toplevel()
  local out = vim.fn.systemlist({ 'git', 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 then return nil end
  return out[1]
end

local function list_modified(toplevel)
  local set = {}
  local function add(args)
    for _, f in ipairs(vim.fn.systemlist(args)) do
      if f ~= '' then set[toplevel .. '/' .. f] = true end
    end
  end
  -- tracked: working tree vs HEAD (staged + unstaged, including deletions)
  add({ 'git', '-C', toplevel, 'diff', '--name-only', 'HEAD' })
  -- untracked
  add({ 'git', '-C', toplevel, 'ls-files', '--others', '--exclude-standard' })
  return set
end

local function relpath(toplevel, path)
  local prefix = toplevel .. '/'
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return path
end

local function read_file_raw(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function git_show_raw(toplevel, rel)
  local s = vim.fn.system({ 'git', '-C', toplevel, 'show', 'HEAD:' .. rel })
  if vim.v.shell_error ~= 0 then return nil end
  return s
end

local function is_binary(toplevel, rel, path)
  -- numstat reports "-\t-\tfile" for binary tracked changes
  local out = vim.fn.systemlist({ 'git', '-C', toplevel, 'diff', '--numstat', 'HEAD', '--', rel })
  if out[1] and out[1]:match('^%-%s+%-%s') then return true end
  -- untracked: scan the working file for NUL bytes
  local raw = read_file_raw(path)
  if raw and raw:find('%z') then return true end
  return false
end

-- Split raw file content into lines with the same semantics as vim.diff:
-- a trailing '\n' terminates the last line without creating an empty one,
-- so '' is no lines, '\n' is one empty line, 'a\n' is one line. Plain
-- vim.split with trimempty would drop that trailing empty line, and the
-- hunk line counts from vim.diff would then index past the array.
local function lines(s)
  if s == nil or s == '' then return {} end
  return vim.split(s:gsub('\n$', ''), '\n', { plain = true })
end

--------------------------------------------------------------------------
-- nvim-tree helpers
--------------------------------------------------------------------------
local function lazy_load_nvim_tree()
  if pcall(require, 'nvim-tree.api') then return end
  require('lazy').load({ plugins = { 'nvim-tree.lua' } })
end

local function get_api()
  if not api then api = require('nvim-tree.api') end
  return api
end

local function tree_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == 'NvimTree' and vim.api.nvim_buf_is_loaded(b) then
      return b
    end
  end
end

-- Read/write nvim-tree's "git_clean" filter, both in the resolved config (so a
-- freshly created explorer picks it up) and on a live explorer's filter state.
-- Avoids toggle(), which is fragile and depends on the prior state being known.
local function set_git_clean(value)
  local config = require('nvim-tree.config')
  local prev = config.g and config.g.filters and config.g.filters.git_clean
  if config.g and config.g.filters then config.g.filters.git_clean = value end
  local ex = require('nvim-tree.core').get_explorer()
  if ex and ex.filters then ex.filters.state.git_clean = value end
  return prev
end

--------------------------------------------------------------------------
-- diff building
--------------------------------------------------------------------------
-- Build a full-file view: every line of the new file is shown (so changes are
-- not stacked together), with added/removed lines interleaved in place.
-- `vim.diff` omits context by default, so we walk its hunks and fill the
-- unchanged gaps between them from the working file.
--
--   disp[i]    = view line, prefixed ' ' (ctx), '+' (add) or '-' (del)
--   map[i]     = 1-based new-side line number (ctx/add); nil for del
--   oldmap[i]  = 1-based old-side line number (ctx/del); nil for add
--   kinds[i]   = 'ctx' | 'add' | 'del'
-- Line numbers come from the @@ hunk headers (not a counter): vim.diff omits
-- unchanged context, so a counter would undercount and break tree-sitter
-- mapping.
local function build_view(old_raw, new_raw)
  local old_lines = lines(old_raw)
  local new_lines = lines(new_raw)
  -- vim.diff omits context by default, so we walk its hunks as line-index
  -- ranges (not the unified text) and fill every unchanged gap between them
  -- (and before/after) with context from the working file, so changes appear
  -- in place rather than stacked together. Each hunk is
  -- {start_old, count_old, start_new, count_new}, 1-based and inclusive.
  local hunks = vim.diff(old_raw or '', new_raw or '', {
    algorithm = 'histogram',
    result_type = 'indices',
  })

  local disp, map, oldmap, kinds = {}, {}, {}, {}
  if #hunks == 0 then
    -- identical: show the whole file as context
    for i, l in ipairs(new_lines) do
      disp[i] = ' ' .. l
      map[i] = i
      oldmap[i] = i
      kinds[i] = 'ctx'
    end
    return disp, map, oldmap, kinds
  end

  local oi, ni = 0, 0            -- 1-based cursors into old/new files
  local next_new = 1             -- next new-file line to emit as context filler

  local function emit_ctx(n)
    -- emit new-file line n (1-based) as a context line
    disp[#disp + 1] = ' ' .. new_lines[n]
    map[#disp] = n
    oldmap[#disp] = n - (ni - oi) -- old-side equivalent line
    kinds[#disp] = 'ctx'
  end

  local function fill_context(upto_new)
    -- emit unchanged new-file lines next_new..upto_new (inclusive)
    while next_new <= upto_new do
      emit_ctx(next_new)
      ni = ni + 1
      oi = oi + 1
      next_new = next_new + 1
    end
  end

  for _, h in ipairs(hunks) do
    local os, oc, ns, nc = h[1], h[2], h[3], h[4]
    -- fill unchanged lines between the previous hunk and this one
    fill_context(ns - 1)
    oi, ni = os, ns
    for k = os, os + oc - 1 do
      disp[#disp + 1] = '-' .. old_lines[k]
      oldmap[#disp] = oi
      kinds[#disp] = 'del'
      oi = oi + 1
    end
    for k = ns, ns + nc - 1 do
      disp[#disp + 1] = '+' .. new_lines[k]
      map[#disp] = ni
      kinds[#disp] = 'add'
      ni = ni + 1
    end
    -- a hunk at the file start with an empty new side (a full deletion)
    -- leaves ni = 0; keep next_new at 1 so the trailing fill no-ops
    next_new = math.max(ni, 1)
  end
  -- trailing context after the last hunk
  fill_context(#new_lines)
  return disp, map, oldmap, kinds
end

-- Replace the middle of long runs of unchanged lines with a single placeholder
-- row (kind 'sep'), keeping KEEP context lines on each side of a change. This
-- hides unrelated code without using folds: the omitted lines simply don't
-- exist in the view, replaced by a `... N unchanged ...` marker. The map/
-- oldmap/kinds arrays are rebuilt in lockstep with disp.
local function collapse_context(disp, map, oldmap, kinds)
  -- `map`/`oldmap` are sparse: del rows have map=nil, add rows have
  -- oldmap=nil. Assigning nil with `t[#t+1] = nil` would NOT extend the array
  -- (the length operator stalls on holes), corrupting every subsequent index.
  -- So append with an explicit counter and store `false` as the sentinel for
  -- "no line on this side" — readers compare against nil/falsy, and the array
  -- stays dense so ipairs(disp)/ipairs(kinds) keep lining up.
  local nd, nm, nom, nk = {}, {}, {}, {}
  local o = 0 -- output row count (1-based); use this instead of #t
  local function push(d, m, om, k)
    o = o + 1
    nd[o] = d
    nm[o] = m or false
    nom[o] = om or false
    nk[o] = k
  end
  local i, n = 1, #disp
  while i <= n do
    if kinds[i] == 'ctx' then
      -- find the full run of context
      local j = i
      while j + 1 <= n and kinds[j + 1] == 'ctx' do j = j + 1 end
      local len = j - i + 1
      if len > 2 * KEEP + 1 then
        -- keep KEEP at the start, placeholder, keep KEEP at the end
        for k = i, i + KEEP - 1 do
          push(disp[k], map[k], oldmap[k], 'ctx')
        end
        local hidden = len - 2 * KEEP
        push(string.format(' ... %d unchanged lines ...', hidden), nil, nil, 'sep')
        for k = j - KEEP + 1, j do
          push(disp[k], map[k], oldmap[k], 'ctx')
        end
      else
        for k = i, j do
          push(disp[k], map[k], oldmap[k], 'ctx')
        end
      end
      i = j + 1
    else
      push(disp[i], map[i], oldmap[i], kinds[i])
      i = i + 1
    end
  end
  return nd, nm, nom, nk
end

--------------------------------------------------------------------------
-- intra-line word diff
--------------------------------------------------------------------------
-- Tokenize a line into word / non-word runs, keeping everything so byte
-- offsets map exactly to buffer columns. Words are identifier-ish runs; the
-- rest (punctuation, whitespace) are passed through as separate tokens.
local function tokenize(line)
  local toks = {} ---@type {s:number,e:number}[] 1-based inclusive byte cols
  local i = 1
  local n = #line
  while i <= n do
    local word = line:match('^[%w_]+', i)
    if word then
      toks[#toks + 1] = { s = i, e = i + #word - 1, t = word }
      i = i + #word
    else
      local other = line:match('^[%w_]*[^%w_]', i) or line:sub(i)
      toks[#toks + 1] = { s = i, e = i + #other - 1, t = other }
      i = i + #other
    end
  end
  return toks
end

-- Given old/new line *content* (without the +/- sign prefix), compute the
-- byte-column ranges of the changed words on each side. Returns:
--   del_ranges = { {s_col0, e_col0}, ... } on the old line
--   add_ranges = { {s_col0, e_col0}, ... } on the new line
-- Columns are 0-based into the content; the caller shifts +1 for the sign.
local function word_diff(old_content, new_content)
  local old_toks, new_toks = tokenize(old_content), tokenize(new_content)
  if #old_toks == 0 or #new_toks == 0 then return {}, {} end

  -- diff the tokens at line granularity: put each token on its own line
  -- (tokens never contain '\n'), so vim.diff's index hunks are token ranges.
  -- Both sides get a trailing '\n' so equal token lines are actually
  -- matched: without it, an unterminated last line is never equal, and a
  -- line like 'beta' -> 'beta X' would diff as fully changed.
  local function join(toks)
    local parts = {}
    for _, tk in ipairs(toks) do parts[#parts + 1] = tk.t end
    return table.concat(parts, '\n') .. '\n'
  end
  local hunks = vim.diff(join(old_toks), join(new_toks), { result_type = 'indices' })
  local old_chg, new_chg = {}, {} -- changed-token index sets
  for _, h in ipairs(hunks) do
    for k = h[1], h[1] + h[2] - 1 do old_chg[k] = true end
    for k = h[3], h[3] + h[4] - 1 do new_chg[k] = true end
  end

  -- merge consecutive changed non-whitespace tokens into one range each
  local del_ranges, add_ranges = {}, {}
  local function push(out, toks, chg)
    local run ---@type {s:number,e:number}?
    local function flush()
      if run then out[#out + 1] = { run.s, run.e }; run = nil end
    end
    for idx = 1, #toks do
      local tk = toks[idx]
      if chg[idx] and tk.t:match('%S') then -- skip pure-whitespace tokens
        local s, e = tk.s - 1, tk.e -- 0-based start, exclusive end
        if run and s == run.e then run.e = e
        else flush(); run = { s = s, e = e } end
      else
        flush()
      end
    end
    flush()
  end
  push(del_ranges, old_toks, old_chg)
  push(add_ranges, new_toks, new_chg)
  return del_ranges, add_ranges
end

--------------------------------------------------------------------------
-- treesitter highlighting
--------------------------------------------------------------------------
-- Parse the old/new file contents in throwaway buffers and lift the highlight
-- captures onto the view buffer. Each view line is prefixed with a sign
-- char ('+', '-', ' '), so capture columns are shifted by 1. `line_map` is the
-- reverse: side_line_number -> view_line_number (0-based) for that side.
local function lang_for_path(abspath)
  local ft = vim.filetype.match({ filename = abspath }) or ''
  return vim.treesitter.language.get_lang(ft)
end

-- Parse `content` (string) as `lang`, returning a list of captures:
--   { {row0, col0, row1, col1, capture_name}, ... }
-- Returns nil if the language has no parser or highlights query.
local function parse_captures(lang, content)
  local ls = lines(content)
  if #ls == 0 then return nil end
  local scratch = vim.api.nvim_create_buf(false, true)
  local caps
  local ok = pcall(function()
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    local parser = vim.treesitter.get_parser(scratch, lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(lang, 'highlights')
    if not tree or not query then return end
    caps = {}
    for id, node in query:iter_captures(tree:root(), scratch, 0, -1) do
      local sr, sc, er, ec = node:range()
      caps[#caps + 1] = { sr, sc, er, ec, query.captures[id] }
    end
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  if not ok then return nil end
  return caps
end

local function highlight_side(buf, caps, line_map, offset)
  if not caps then return end
  for _, c in ipairs(caps) do
    local sr, sc, er, ec, name = c[1], c[2], c[3], c[4], c[5]
    local view_line = line_map[sr + 1] -- side lines are 1-based in line_map
    if view_line then
      local row = offset + view_line -- 0-based extmark row
      -- multi-line captures: only highlight the first line segment for simplicity
      if sr == er then
        pcall(vim.api.nvim_buf_set_extmark, buf, ts_ns, row, sc + 1, {
          end_row = row,
          end_col = ec + 1,
          hl_group = '@' .. name,
          priority = 110, -- above the line background (default 100)
        })
      end
    end
  end
end

local function apply_treesitter(buf, abspath, map, oldmap, kinds, old_raw, new_raw)
  vim.api.nvim_buf_clear_namespace(buf, ts_ns, 0, -1)
  local offset = vim.b[buf].diffview_offset or 0
  local lang = lang_for_path(abspath)
  if not lang then return end

  -- new side (ctx + add lines): highlight from the working file
  if new_raw and new_raw ~= '' then
    local new_rev = {}
    for i, n in pairs(map or {}) do
      if n then new_rev[n] = i - 1 end
    end
    highlight_side(buf, parse_captures(lang, new_raw), new_rev, offset)
  end

  -- old side (del lines only; ctx was already highlighted from the new side,
  -- so skip it to avoid stacking duplicate extmarks on every context line)
  if old_raw and old_raw ~= '' then
    local del_rev = {}
    for i, o in pairs(oldmap or {}) do
      if o and kinds and kinds[i] == 'del' then del_rev[o] = i - 1 end
    end
    highlight_side(buf, parse_captures(lang, old_raw), del_rev, offset)
  end
end

--------------------------------------------------------------------------
-- gitsigns gutter signs
--------------------------------------------------------------------------
-- The gutter marks added/removed rows with gitsigns' highlight groups and
-- its configured vertical-bar glyph: both sides of a change show the same
-- `add` sign text (like gitsigns' change/changedelete signs), with the
-- per-side highlight so add and del rows still differ in color. If gitsigns
-- is absent, fall back to plain +/- in the view's own tints. Resolved once
-- per session and cached.
local sign_cache ---@type {add:{text:string,hl:string}, del:{text:string,hl:string}}?
local function resolve_gitsigns_signs()
  if sign_cache then return sign_cache end
  local loaded = pcall(require, 'gitsigns')
  if not loaded then
    pcall(function() require('lazy').load({ plugins = { 'gitsigns.nvim' } }) end)
    loaded = pcall(require, 'gitsigns')
  end
  if loaded then
    local signs = require('gitsigns.config').config.signs
    if signs and signs.add and signs.delete then
      local function sign(ty)
        -- gitsigns names its groups GitSignsAdd / GitSignsDelete / ...
        return {
          text = signs[ty].text,
          hl = 'GitSigns' .. ty:sub(1, 1):upper() .. ty:sub(2),
        }
      end
      local add_s = sign('add')
      local del_s = sign('delete')
      del_s.text = add_s.text -- same bar for both; only the color differs
      sign_cache = { add = add_s, del = del_s }
      return sign_cache
    end
  end
  sign_cache = {
    add = { text = '+', hl = 'DiffViewAdd' },
    del = { text = '-', hl = 'DiffViewDel' },
  }
  return sign_cache
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
-- Define the diff highlight groups. Called from setup(), on ColorScheme, and
-- right before each render so the groups are always present regardless of
-- theme load timing or transparent-mode clearing.
local function define_highlights()
  -- Line tints: muted, low-saturation green/red over onedark's dark bg.
  vim.api.nvim_set_hl(0, 'DiffViewAdd', { bg = '#2f5d44' })
  vim.api.nvim_set_hl(0, 'DiffViewDel', { bg = '#5d3338' })
  vim.api.nvim_set_hl(0, 'DiffViewHeader', { bg = '#393f4a', bold = true })
  -- Placeholder row for hidden unchanged runs: GitHub-style folded-separator
  -- tint — a muted blue-grey band that reads as "collapsed code".
  vim.api.nvim_set_hl(0, 'DiffViewSep', { bg = '#2e3f56' })
  -- Changed-word tints: a step brighter and slightly more saturated than the
  -- line tint, same hue family, so changed words read as "the same green/red,
  -- lit up" rather than a clashing neon patch.
  vim.api.nvim_set_hl(0, 'DiffViewAddBright', { bg = '#3d7a59' })
  vim.api.nvim_set_hl(0, 'DiffViewDelBright', { bg = '#7a4448' })
end

local function setup_view_window(w)
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  -- fixed-width gutter for the gitsigns-style add/delete signs ('yes' keeps
  -- it reserved on every line, so the code never shifts when jumping hunks)
  vim.wo[w].signcolumn = 'yes:1'
  -- statuscolumn renders each view line's real source-file line number:
  -- the new-side number for context/added lines, the old-side number for
  -- removed lines. Evaluated per screen line with v:lnum set to the row.
  -- `%s` draws the sign column: a non-empty statuscolumn takes over the
  -- whole gutter area (fold + sign + number), so the gitsigns-style
  -- add/delete signs must be requested explicitly or they never render.
  vim.wo[w].statuscolumn = '%s%=%{v:lua.require("diffview")._linecol()} '
  -- no folding: show the whole file with all context lines expanded.
  vim.wo[w].foldenable = false
end

local function show_in_window(buf)
  -- reuse an existing view window, else a non-tree window, else vsplit
  local wins = vim.api.nvim_list_wins()
  local function win_ft(w)
    local ok, b = pcall(vim.api.nvim_win_get_buf, w)
    return ok and vim.bo[b].filetype or ''
  end
  local target
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) and win_ft(w) == 'diffview' then
      target = w
      break
    end
  end
  if not target then
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_is_valid(w) and win_ft(w) ~= 'NvimTree' then
        target = w
        break
      end
    end
  end
  if not target then
    vim.cmd('vsplit')
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
  setup_view_window(target)
end

-- Highlight the changed words within each run of adjacent removed/added lines.
-- Removed and added lines are paired positionally (del[1]↔add[1], …) and
-- word-diffed; changed words get a brighter background on top of the line tint.
-- Unpaired changed lines keep the whole-line tint only (no word highlight).
local function compute_word_diffs(buf, offset, disp, kinds)
  local i = 1
  local n = #kinds
  local row0 = offset - 1 -- 0-based buffer row of disp[1]
  while i <= n do
    if kinds[i] == 'del' or kinds[i] == 'add' then
      -- gather one contiguous changed run
      local dels, adds = {}, {}
      while i <= n and (kinds[i] == 'del' or kinds[i] == 'add') do
        if kinds[i] == 'del' then dels[#dels + 1] = i else adds[#adds + 1] = i end
        i = i + 1
      end
      -- pair del/add lines positionally and word-diff each pair
      for k = 1, math.min(#dels, #adds) do
        local di, ai = dels[k], adds[k]
        -- strip the sign prefix to get content
        local dcontent = disp[di]:sub(2)
        local acontent = disp[ai]:sub(2)
        local dranges, aranges = word_diff(dcontent, acontent)
        for _, r in ipairs(dranges) do
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, row0 + di, r[1] + 1, {
            end_col = r[2] + 1,
            hl_group = 'DiffViewDelBright',
            priority = 200, -- above the line bg (100) and tree-sitter (110)
          })
        end
        for _, r in ipairs(aranges) do
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, row0 + ai, r[1] + 1, {
            end_col = r[2] + 1,
            hl_group = 'DiffViewAddBright',
            priority = 200,
          })
        end
      end
    else
      i = i + 1
    end
  end
end

local function render(buf, abspath, rel, disp, map, oldmap, kinds, counts)
  define_highlights() -- ensure diff highlight groups exist before drawing
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = {
    string.format('%s   +%d -%d', rel, counts.add, counts.del),
    '',
  }
  local offset = #lines -- 1-based count of header lines
  for _, l in ipairs(disp) do
    lines[#lines + 1] = l
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = 'DiffViewHeader' })
  for i, k in ipairs(kinds) do
    if k == 'sep' then
      -- placeholder for hidden unchanged lines: muted full-line tint
      vim.api.nvim_buf_set_extmark(buf, ns, offset + i - 1, 0, {
        line_hl_group = 'DiffViewSep',
      })
    elseif k ~= 'ctx' then
      -- Paint the line tint as an INLINE hl_group spanning the whole line
      -- (NOT line_hl_group): line_hl_group draws at the line-fill layer and
      -- renders OVER inline ranges regardless of priority, so the brighter
      -- changed-word extmark could never show through. Two inline hl_groups
      -- compose by priority, letting the word highlight win on its columns.
      -- End the range on the NEXT line (end_row = row + 1, end_col = 0) so it
      -- covers this line's EOL; hl_eol then extends the tint to the end of
      -- the screen line (GitHub style) instead of stopping at the text.
      vim.api.nvim_buf_set_extmark(buf, ns, offset + i - 1, 0, {
        end_row = offset + i,
        end_col = 0,
        hl_group = k == 'add' and 'DiffViewAdd' or 'DiffViewDel',
        hl_eol = true,
        priority = 90,
      })
    end
  end
  -- gutter signs for added/removed rows, styled after gitsigns' own config.
  -- Placed in the same namespace as the tints, so re-renders replace them.
  local signs = resolve_gitsigns_signs()
  for i, k in ipairs(kinds) do
    if k == 'add' or k == 'del' then
      local s = k == 'add' and signs.add or signs.del
      vim.api.nvim_buf_set_extmark(buf, ns, offset + i - 1, 0, {
        sign_text = s.text,
        sign_hl_group = s.hl,
      })
    end
  end
  -- brighter highlights on the changed words within each +/- run
  compute_word_diffs(buf, offset, disp, kinds)

  vim.bo[buf].modifiable = false
  vim.b[buf].diffview_map = map
  vim.b[buf].diffview_oldmap = oldmap
  vim.b[buf].diffview_kinds = kinds
  vim.b[buf].diffview_abspath = abspath
  vim.b[buf].diffview_offset = offset
end

--------------------------------------------------------------------------
-- buffer management
--------------------------------------------------------------------------
local function find_view_buf(abspath)
  for _, b in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].diffview_abspath == abspath then
      return b
    end
  end
end

local function create_view_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'diffview'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'diffview://' .. buf)

  vim.keymap.set('n', 'q', function()
    -- close the view; close() reopens the shown source file in this window
    M.close()
  end, { buffer = buf, silent = true, desc = 'diffview: close and open source' })
  vim.keymap.set('n', '<CR>', M.jump_to_source, { buffer = buf, silent = true, desc = 'diffview: open source' })
  vim.keymap.set('n', ']]', function() M.jump_hunk(1) end, { buffer = buf, silent = true, desc = 'diffview: next change' })
  vim.keymap.set('n', '[[', function() M.jump_hunk(-1) end, { buffer = buf, silent = true, desc = 'diffview: prev change' })
  vim.keymap.set('n', 'dd', M.revert_line, { buffer = buf, nowait = true, silent = true, desc = 'diffview: revert line change' })
  vim.keymap.set('n', 'u', M.undo_revert, { buffer = buf, nowait = true, silent = true, desc = 'diffview: undo revert' })

  state.buffers[#state.buffers + 1] = buf
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      for i, b in ipairs(state.buffers) do
        if b == buf then
          table.remove(state.buffers, i)
          break
        end
      end
    end,
  })
  return buf
end

local function open_diff(abspath)
  local toplevel = state.toplevel
  local rel = relpath(toplevel, abspath)

  local disp, map, oldmap, kinds, counts, old_raw, new_raw
  local binary = is_binary(toplevel, rel, abspath)
  if binary then
    disp = { 'Binary file differs (not shown)' }
    map, oldmap, kinds, counts = {}, {}, { 'del' }, { add = 0, del = 1 }
  else
    old_raw = git_show_raw(toplevel, rel) -- nil for untracked files
    new_raw = read_file_raw(abspath)      -- nil for deleted files
    disp, map, oldmap, kinds = build_view(old_raw, new_raw)
    disp, map, oldmap, kinds = collapse_context(disp, map, oldmap, kinds)
    counts = { add = 0, del = 0 }
    for _, k in ipairs(kinds) do
      if k == 'add' then counts.add = counts.add + 1 end
      if k == 'del' then counts.del = counts.del + 1 end
    end
  end

  local buf = find_view_buf(abspath) or create_view_buf()
  vim.b[buf].diffview_binary = binary -- blocks dd on binary files
  render(buf, abspath, rel, disp, map, oldmap, kinds, counts)
  apply_treesitter(buf, abspath, map, oldmap, kinds, old_raw, new_raw)
  show_in_window(buf)
end

--------------------------------------------------------------------------
-- working-tree edits (dd / u)
--------------------------------------------------------------------------
-- Apply one line edit to the working file's line list and return the new
-- content ('delete' removes the line at `at`, 'insert' puts `content` there,
-- both 1-based). The current trailing newline is preserved; when a restored
-- line lands at the END of a file that lacks one, it inherits it from the
-- HEAD side, so the revert shows as complete instead of a lone newline diff.
local function edit_content(ls, op, at, content, trailing_new, old_trailing, at_end)
  if op == 'delete' then
    table.remove(ls, at)
  else
    table.insert(ls, at, content)
  end
  local out = table.concat(ls, '\n')
  local trailing = trailing_new
  if not trailing and at_end and old_trailing then trailing = true end
  if trailing and #ls > 0 then out = out .. '\n' end
  return out
end

-- Write `content` to the working file; nil means the pre-edit file was absent
-- (a deleted file being restored, or reverted to absent again), so remove it.
-- Returns false after notifying when the filesystem call fails.
local function write_working_file(abspath, content)
  if content == nil then
    local ok, err = os.remove(abspath)
    if not ok then
      vim.notify('diffview: cannot remove ' .. abspath .. ': ' .. tostring(err), vim.log.levels.ERROR)
    end
    return ok
  end
  local f, err = io.open(abspath, 'wb')
  if not f then
    vim.notify('diffview: cannot write ' .. abspath .. ': ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  f:write(content)
  f:close()
  return true
end

-- Reload open, unmodified buffers of the edited file so the revert shows up
-- in the editor too. Buffers with unsaved changes are left alone.
local function reload_open_buffers(abspath)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and not vim.bo[b].modified
        and vim.api.nvim_buf_get_name(b) == abspath then
      pcall(vim.api.nvim_buf_call, b, function() vim.cmd('edit!') end)
    end
  end
end

-- Re-scan the modified set; when the edited file's status changed (dirty ->
-- clean or clean -> dirty), reload the tree so its git filter stays honest.
local function refresh_modified(abspath)
  local newmod = list_modified(state.toplevel)
  if newmod[abspath] ~= state.modified[abspath] then
    pcall(function() get_api().tree.reload() end)
  end
  state.modified = newmod
end

-- Finish a working-tree edit: refresh open buffers and the tree, then
-- re-render the view from the new working-tree state.
local function after_edit(abspath)
  reload_open_buffers(abspath)
  refresh_modified(abspath)
  open_diff(abspath)
end

--------------------------------------------------------------------------
-- in-buffer actions
--------------------------------------------------------------------------
-- dd: revert the change on the cursor line — an added line is deleted from
-- the working file, a removed line is restored into it. The edit is written
-- straight to disk (the view's source of truth), the view re-renders and the
-- cursor moves to the next remaining change line. Each edit is pushed onto
-- the buffer's undo stack as before/after content snapshots, so `u` can
-- restore the exact prior state.
function M.revert_line()
  local buf = vim.api.nvim_get_current_buf()
  local abspath = vim.b[buf].diffview_abspath
  if not abspath or vim.b[buf].diffview_binary then
    vim.notify('diffview: cannot revert this view', vim.log.levels.WARN)
    return
  end
  local offset = vim.b[buf].diffview_offset or 0
  local kinds = vim.b[buf].diffview_kinds
  local row = vim.api.nvim_win_get_cursor(0)[1] - offset
  local k = kinds and kinds[row]
  if k ~= 'add' and k ~= 'del' then
    vim.notify('diffview: not on a changed line', vim.log.levels.WARN)
    return
  end

  local toplevel = state.toplevel
  local new_raw = read_file_raw(abspath)
  local ls = new_raw and lines(new_raw) or {}
  local content = vim.api.nvim_buf_get_lines(buf, offset + row - 1, offset + row, false)[1]:sub(2)
  local trailing_new = new_raw and new_raw:sub(-1) == '\n' or false
  local function stale()
    vim.notify('diffview: working file changed; reopen the view', vim.log.levels.WARN)
  end

  local out, entry
  if k == 'add' then
    -- delete the added line from the working file
    local line = vim.b[buf].diffview_map[row]
    if ls[line] ~= content then return stale() end
    out = edit_content(ls, 'delete', line, nil, trailing_new, false, false)
    entry = { kind = 'add', pos = line, content = content, old_line = nil }
  else
    -- restore the removed line at the new-side position of its old line:
    -- the old-side number minus the deleted lines before it, plus the added
    -- lines before it (a surviving old line maps to one new line, and an
    -- added line also occupies one slot ahead of this line in the new file).
    -- Exact for every case — including end-of-file deletions, where vim.diff
    -- anchors the hunk at the new side's start, and del runs that follow
    -- earlier add hunks.
    local L = vim.b[buf].diffview_oldmap[row]
    local dels_before, adds_before = 0, 0
    for i = 1, row - 1 do
      if kinds[i] == 'del' then
        dels_before = dels_before + 1
      elseif kinds[i] == 'add' then
        adds_before = adds_before + 1
      end
    end
    local pos = L - dels_before + adds_before
    local at_end = pos == #ls + 1
    -- stale-view guard: the new-side line at the insertion point must still
    -- hold the content the view shows
    local anchor
    for i = 1, #kinds do
      if vim.b[buf].diffview_map[i] == pos then anchor = i break end
    end
    if anchor and ls[pos] ~= vim.api.nvim_buf_get_lines(buf, offset + anchor - 1, offset + anchor, false)[1]:sub(2) then
      return stale()
    end
    local old_trailing = false
    if at_end and not trailing_new then
      local old_raw = git_show_raw(toplevel, relpath(toplevel, abspath))
      old_trailing = old_raw and old_raw:sub(-1) == '\n' or false
    end
    out = edit_content(ls, 'insert', pos, content, trailing_new, old_trailing, at_end)
    entry = { kind = 'del', pos = pos, content = content, old_line = vim.b[buf].diffview_oldmap[row] }
  end

  if not write_working_file(abspath, out) then return end
  entry.before = new_raw -- nil when the file was absent
  entry.after = out
  local stack = vim.b[buf].diffview_undo or {}
  stack[#stack + 1] = entry
  vim.b[buf].diffview_undo = stack

  after_edit(abspath)

  -- land the cursor on the next remaining change line. The re-render keeps
  -- the cursor's line number, so scan forward from there — the row under it
  -- may now hold the rest of the same hunk, which still counts as "next".
  local kinds2 = vim.b[buf].diffview_kinds
  local off2 = vim.b[buf].diffview_offset or 0
  for i = math.max(vim.api.nvim_win_get_cursor(0)[1], off2 + 1), vim.api.nvim_buf_line_count(buf) do
    local kk = kinds2[i - off2]
    if kk == 'add' or kk == 'del' then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      break
    end
  end
end

-- u: reverse the most recent dd. The working file must still match the
-- recorded after-state (otherwise the entry is stale and gets dropped); it is
-- then restored to the exact recorded before-state. The cursor returns to
-- the row the dd touched.
function M.undo_revert()
  local buf = vim.api.nvim_get_current_buf()
  local stack = vim.b[buf].diffview_undo
  local entry = stack and stack[#stack]
  if not entry then
    vim.notify('diffview: nothing to undo', vim.log.levels.INFO)
    return
  end

  local abspath = vim.b[buf].diffview_abspath
  if read_file_raw(abspath) ~= entry.after then
    table.remove(stack, #stack)
    vim.b[buf].diffview_undo = stack -- vim.b values are copies; write back
    vim.notify('diffview: working file changed; skipping undo', vim.log.levels.WARN)
    return
  end
  if not write_working_file(abspath, entry.before) then return end
  table.remove(stack, #stack)
  vim.b[buf].diffview_undo = stack -- vim.b values are copies; write back

  after_edit(abspath)

  -- return the cursor to the reverted line: an added line is back as a
  -- context row carrying its new-side number; a removed line is a del row
  -- again under its old-side number.
  local kinds = vim.b[buf].diffview_kinds
  local offset = vim.b[buf].diffview_offset or 0
  local target
  if entry.kind == 'add' then
    local map = vim.b[buf].diffview_map
    for i = 1, #map do
      if map[i] == entry.pos then target = i break end
    end
  else
    local oldmap = vim.b[buf].diffview_oldmap
    for i = 1, #oldmap do
      if kinds[i] == 'del' and oldmap[i] == entry.old_line then target = i break end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { offset + target, 0 })
  end
end

function M.jump_to_source()
  local buf = vim.api.nvim_get_current_buf()
  local abspath = vim.b[buf].diffview_abspath
  local map = vim.b[buf].diffview_map
  local offset = vim.b[buf].diffview_offset or 0
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local target = map and map[row - offset]

  -- open the real file in the current window, jumping to the new-side line
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

-- Jump to the next/previous change hunk. A hunk is a contiguous run of
-- add/del rows (a removed line followed by its replacement is treated as ONE
-- hunk, not two). Non-change rows (context, separator, header) break the run.
function M.jump_hunk(dir)
  local buf = vim.api.nvim_get_current_buf()
  local offset = vim.b[buf].diffview_offset or 0
  local kinds = vim.b[buf].diffview_kinds
  -- screen line -> view row index (1-based), nil for header rows
  local function row_of(sline)
    if sline <= offset then return nil end
    return sline - offset
  end
  local function is_change(row)
    return row and kinds and (kinds[row] == 'add' or kinds[row] == 'del')
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(buf)
  -- scan range: header lines (<= offset) are not content; when the cursor is
  -- in/above the header, start from the first view line (offset+1) going down,
  -- and never go up. Otherwise step off the current line.
  local i
  if cur <= offset then
    i = (dir > 0) and (offset + 1) or nil
  else
    i = cur + dir
  end
  -- If we start inside a hunk, skip past the whole hunk first so the cursor
  -- lands on the *next* hunk rather than the next line of the current one.
  if is_change(row_of(cur)) then
    while i and is_change(row_of(i)) do i = i + dir end
  end
  while i and i > offset and i <= total do
    if is_change(row_of(i)) then
      -- When going backward, land on the FIRST line of the hunk (lowest row)
      -- so ]]/[[ are symmetric: both bring you to a hunk's start, not its end.
      if dir < 0 then
        while is_change(row_of(i - 1)) do i = i - 1 end
      end
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
    i = i + dir
  end
end

-- statuscolumn callback: return the source-file line number for the screen
-- line currently being rendered (v:lnum). Removed lines use the old-side
-- number, everything else uses the new-side number; header lines are blank.
function M._linecol()
  local lnum = vim.v.lnum
  local offset = vim.b.diffview_offset or 0
  if lnum <= offset then return '' end
  local i = lnum - offset
  local kinds = vim.b.diffview_kinds
  local k = kinds and kinds[i]
  if k == 'del' then
    local oldmap = vim.b.diffview_oldmap
    local n = oldmap and oldmap[i]
    return n and tostring(n) or ''
  end
  local map = vim.b.diffview_map
  local n = map and map[i]
  return n and tostring(n) or ''
end

--------------------------------------------------------------------------
-- nvim-tree hijack
--------------------------------------------------------------------------
local function hijack(buf)
  if state.saved_keymaps[buf] then return end -- already hijacked
  local saved = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    saved[vim.fn.trim(m.lhs)] = m
  end
  state.saved_keymaps[buf] = saved
  for _, key in ipairs(OPEN_KEYS) do
    vim.keymap.set('n', key, function() M.open_under_cursor() end, {
      buffer = buf, nowait = true, silent = true, desc = 'diffview: open diff',
    })
  end
end

local function restore(buf)
  local saved = state.saved_keymaps[buf]
  if not saved then return end
  for _, key in ipairs(OPEN_KEYS) do
    pcall(vim.keymap.del, 'n', key, { buffer = buf })
    local m = saved[key]
    if m then
      if m.callback then
        vim.keymap.set('n', key, m.callback, { buffer = buf, nowait = true, silent = true })
      elseif m.rhs and m.rhs ~= '' then
        vim.api.nvim_buf_set_keymap(buf, 'n', key, m.rhs, { nowait = true, silent = true })
      end
    end
  end
  state.saved_keymaps[buf] = nil
end

function M.open_under_cursor()
  local node = get_api().tree.get_node_under_cursor()
  if not node then return end
  if node.type == 'directory' then
    get_api().node.open.edit() -- toggle the directory
    return
  end
  local path = node.absolute_path
  if state.modified[path] then
    open_diff(path)
  else
    get_api().node.open.edit() -- fallback: open the raw file
  end
end

--------------------------------------------------------------------------
-- public API
--------------------------------------------------------------------------
-- Reset all transient state. Used on close and as a safety net when open()
-- fails partway through, so a crashed run never leaves state.active stuck.
local function reset_state()
  if state.saved_clean ~= nil then
    set_git_clean(state.saved_clean)
  end
  state.active = false
  state.toplevel = nil
  state.modified = {}
  state.saved_clean = nil
end

-- If the buffer in the current window is a real file that has uncommitted
-- changes, return its absolute path; otherwise nil. Used so <Leader>dv shows
-- the diff for whatever file the user is already editing, falling back to the
-- first modified file.
local function current_buf_modified(modified)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  if vim.bo[buf].buftype ~= '' then return nil end -- skip nofile/tree/quickfix
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then return nil end
  local path = vim.fn.fnamemodify(name, ':p')
  if modified[path] then return path end
  return nil
end

-- Pick the first modified file in a deterministic order (shortest relpath first).
local function pick_first_modified(modified, toplevel)
  local paths = {}
  for path in pairs(modified) do
    paths[#paths + 1] = path
  end
  table.sort(paths, function(a, b)
    return relpath(toplevel, a) < relpath(toplevel, b)
  end)
  return paths[1]
end

function M.open()
  lazy_load_nvim_tree()

  local toplevel = git_toplevel()
  if not toplevel then
    vim.notify('diffview: not in a git repository', vim.log.levels.WARN)
    return
  end
  local modified = list_modified(toplevel)
  if vim.tbl_isempty(modified) then
    vim.notify('diffview: no modified files', vim.log.levels.INFO)
    return
  end

  -- Capture the file currently being edited BEFORE opening the tree, since
  -- tree.open() may steal focus and change the current buffer.
  local current = current_buf_modified(modified)

  -- Enable the git_clean filter BEFORE opening the tree, so the very first draw
  -- already shows only git-dirty files. tree.open() loads git status and draws
  -- synchronously, so no separate git/tree reload is needed (and api.git.reload
  -- races with initialization, erroring when the git module isn't ready).
  state.saved_clean = set_git_clean(true)

  local ok, err = pcall(function()
    local api = get_api()
    api.tree.open()
    -- If the explorer was already cached from a prior session, open() reused it
    -- without re-applying the filter; force a redraw so dirty files are shown.
    api.tree.reload()
  end)
  if not ok then
    reset_state()
    vim.notify('diffview: failed to open tree: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end

  state.toplevel = toplevel
  state.modified = modified
  state.active = true -- set last, only after everything succeeded

  -- hijack the current tree buffer (new buffers are handled by the FileType autocmd)
  local buf = tree_buf()
  if buf then hijack(buf) end

  -- Show the diff for the file currently being edited, if it has changes;
  -- otherwise fall back to the first modified file.
  local first = current or pick_first_modified(modified, toplevel)
  if first then
    open_diff(first)
    pcall(get_api().tree.find_file, first)
  end
end

function M.close()
  if not state.active then return end

  -- Reopen the source file of the currently-visible diff in its window, so the
  -- view doesn't collapse to an empty buffer on close. Swap the diff buffer for
  -- the real file BEFORE deleting buffers, so the cleanup never touches the
  -- window being edited.
  local reopen_path, reopen_target
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local ok, b = pcall(vim.api.nvim_win_get_buf, w)
      if ok and vim.bo[b].filetype == 'diffview' then
        reopen_path = vim.b[b].diffview_abspath
        local map = vim.b[b].diffview_map
        local offset = vim.b[b].diffview_offset or 0
        local row = vim.api.nvim_win_get_cursor(w)[1]
        reopen_target = map and map[row - offset]
        if reopen_path then
          vim.api.nvim_set_current_win(w)
          vim.cmd('edit ' .. vim.fn.fnameescape(reopen_path))
        end
        break
      end
    end
  end

  for buf in pairs(state.saved_keymaps) do
    if vim.api.nvim_buf_is_valid(buf) then restore(buf) end
  end

  for _, b in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
  state.buffers = {}

  reset_state()

  local api = get_api()
  api.tree.reload()

  if reopen_target then
    pcall(vim.api.nvim_win_set_cursor, 0, { reopen_target, 0 })
  end
  if reopen_path then
    pcall(api.tree.find_file, reopen_path)
  end
end

-- Toggle the diff view: open if inactive, close if active.
function M.toggle()
  if state.active then
    M.close()
  else
    M.open()
  end
end

--------------------------------------------------------------------------
-- setup
--------------------------------------------------------------------------
function M.setup()
  vim.api.nvim_create_user_command('DiffView', function() M.toggle() end, {})
  vim.keymap.set('n', '<Leader>dv', function() M.toggle() end, { desc = 'diffview: toggle' })

  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })

  -- re-hijack when the tree buffer is (re)created while view is active
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'NvimTree',
    callback = function(ev)
      if state.active then hijack(ev.buf) end
    end,
  })
end

-- Exposed for ad-hoc debugging from the command line.
M.state = state

return M
