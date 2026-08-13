local config = require("punchlist.config")
local store = require("punchlist.store")
local signs = require("punchlist.signs")
local float = require("punchlist.float")
local picker = require("punchlist.picker")
local prompt = require("punchlist.prompt")
local util = require("punchlist.util")
local anchor = require("punchlist.anchor")
local track = require("punchlist.track")
local register = require("punchlist.register")

local M = {}

-- Undo stack for deletes (cursor deletes, picker deletes, and the overlapping
-- annotations a new range annotation replaces). Each entry is a *group*, because one
-- action can destroy several annotations at once and undoing half of that would be
-- worse than not undoing at all.
---@alias punchlist.Deleted { repo_root: string, rel_path: string, annotation: table }
---@type punchlist.Deleted[][]
local undo_stack = {}
local UNDO_LIMIT = 20

-- Width budget for the code/body excerpts in the reanchor/move confirmations,
-- which are narrow floats and shouldn't wrap a long line into three rows.
local REANCHOR_PREVIEW_MAX = 60

-- "12" for a single line, "12-15" for a range -- matches how `util.location`
-- renders stored annotations.
local function range_label(start_line, end_line)
  return start_line == end_line and tostring(start_line) or (start_line .. "-" .. end_line)
end

-- Corrects drifted positions before every user action, then reports where we
-- are: (bufnr, rel_path, repo_root). Doing the sync here is what lets the rest
-- of the codebase (find_annotation_at_line, delete_by_id, the overlap merge in
-- upsert_line_annotation) stay position-based and unmodified. The sync is a
-- no-op when `line_tracking` is off or the buffer isn't attached.
---@return integer bufnr, string? rel_path, string repo_root
local function synced_target(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Buffers that were already open when setup() ran never saw BufReadPost.
  track.ensure_attached(bufnr)
  track.sync(bufnr)
  local rel_path, repo_root = util.relative_path(bufnr)
  return bufnr, rel_path, repo_root
end

--- Redraws the gutter glyphs/virtual text for `bufnr` (current buffer by
--- default) from whatever is currently in the store for its file.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not util.is_file_buf(bufnr) then
    return
  end
  local rel_path, repo_root = util.relative_path(bufnr)
  if not rel_path then
    return
  end
  signs.render(bufnr, store.get_file_annotations(repo_root, rel_path))
end

--- Redraws every loaded buffer. Needed whenever an action can affect files
--- other than the current one (picker deletes, clear-all).
function M.refresh_all()
  util.loaded_bufs():each(M.refresh)
end

local function is_visual_mode()
  local mode = vim.api.nvim_get_mode().mode
  return mode:sub(1, 1):match("[vV\22]") ~= nil
end

-- Reads the active visual selection's line range using the "v" (selection
-- start) and "." (cursor) positions, which stay valid *while still in
-- Visual mode* -- unlike '</'> marks, which only update once you leave it.
local function visual_range()
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  return start_line, end_line
end

-- Shows the destination of a pending reanchor/move rather than describing it:
-- paints the target lines in the code window and parks the cursor on them so
-- the confirmation float lands next to them.
--
-- Returns `done` (drop the paint) and `restore` (put the cursor back), for the
-- confirm and cancel paths respectively -- backing out of a confirmation
-- shouldn't move the user.
---@return fun() done, fun() restore
local function stage_target(bufnr, start_line, end_line, line_count)
  signs.highlight_pending_range(bufnr, start_line, end_line)
  local win = vim.api.nvim_get_current_win()
  local saved_cursor = vim.api.nvim_win_get_cursor(win)
  if end_line <= line_count then
    vim.api.nvim_win_set_cursor(win, { end_line, 0 })
  end
  return function()
    signs.clear_pending_range(bufnr)
  end, function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, saved_cursor)
    end
  end
end

-- Resolves the target range for an action that accepts "the cursor line, the
-- visual selection, or an Ex range", leaving visual mode if it was in it.
---@return integer start_line, integer end_line
local function target_range(explicit_start, explicit_end)
  if explicit_start then
    return explicit_start, explicit_end or explicit_start
  end
  if is_visual_mode() then
    local start_line, end_line = visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    return start_line, end_line
  end
  local line = vim.fn.line(".")
  return line, line
end

--- Pushes a group of deleted annotations onto the undo stack.
---@param entries punchlist.Deleted[]
function M.stash_deleted(entries)
  if #entries == 0 then
    return
  end
  table.insert(undo_stack, vim.deepcopy(entries))
  if #undo_stack > UNDO_LIMIT then
    table.remove(undo_stack, 1)
  end
end

--- Restores the most recent group of deleted annotations.
function M.restore_deleted()
  local group = table.remove(undo_stack)
  if not group then
    util.notify("nothing to restore", vim.log.levels.WARN)
    return
  end
  for _, entry in ipairs(group) do
    store.upsert_line_annotation(entry.repo_root, entry.rel_path, entry.annotation)
    track.resync_path(entry.repo_root, entry.rel_path)
  end
  M.refresh_all()
  util.notify(#group == 1 and "annotation restored" or (#group .. " annotations restored"))
end

--- Adds/edits a line (or visual-range) annotation on the current buffer.
--- `explicit_start`/`explicit_end` let callers (e.g. Ex commands with a
--- range) bypass the mode-based detection.
function M.annotate(intent, explicit_start, explicit_end)
  local bufnr, rel_path, repo_root = synced_target()
  if not rel_path then
    util.notify("buffer has no file to annotate on", vim.log.levels.WARN)
    return
  end

  -- Figure the lines the annotation applies to
  local start_line, end_line
  if explicit_start then
    start_line, end_line = explicit_start, explicit_end or explicit_start
  elseif is_visual_mode() then
    start_line, end_line = visual_range()
    -- Leave visual mode before opening the editor.
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    start_line = vim.fn.line(".")
    end_line = start_line
  end

  -- This lets us view/edit an annotation that applies to multiple lines by
  -- selecting just one of the lines it applies to
  local existing = store.find_annotation_at_line(repo_root, rel_path, start_line)
  if existing then
    start_line, end_line = existing.start_line, existing.end_line
    intent = intent or existing.intent
  end
  intent = intent or "fix"

  -- Leaving visual mode drops the selection highlight, so repaint the range
  -- for as long as the editor is open. Otherwise you're writing about code you
  -- can no longer identify.
  if end_line > start_line then
    signs.highlight_pending_range(bufnr, start_line, end_line)
  end

  -- Open the editor at the bottom of the range, but put the cursor back if the
  -- user backs out -- cancelling shouldn't move them.
  local win = vim.api.nvim_get_current_win()
  local saved_cursor = vim.api.nvim_win_get_cursor(win)
  if end_line >= start_line and end_line <= vim.api.nvim_buf_line_count(bufnr) then
    vim.api.nvim_win_set_cursor(win, { end_line, 0 })
  end

  local function done()
    signs.clear_pending_range(bufnr)
  end

  float.edit({
    title = string.format("%s %s:%d-%d", intent:upper(), rel_path, start_line, end_line),
    intent = intent,
    -- Keeps the one-line prompt off the annotated lines (see `float.input`).
    span = { start_line = start_line, end_line = end_line },
    initial_body = existing and existing.body or "",
    on_submit = function(body)
      done()
      -- Editing a body must not silently re-anchor: staleness is only ever
      -- cleared deliberately, via `reanchor_at_cursor`.
      local captured = existing and existing.anchor or anchor.capture(bufnr, start_line, end_line)
      local replaced = store.upsert_line_annotation(repo_root, rel_path, {
        start_line = start_line,
        end_line = end_line,
        intent = intent,
        body = body,
        anchor = captured,
        orphaned = existing and existing.orphaned or nil,
      })
      M.stash_deleted(vim.tbl_map(function(annotation)
        return { repo_root = repo_root, rel_path = rel_path, annotation = annotation }
      end, replaced))
      track.resync_path(repo_root, rel_path)
      M.refresh(bufnr)

      if vim.trim(body) == "" then
        util.notify("annotation cleared (restore with :PunchlistUndo)", nil, { id = "punchlist_save" })
      elseif #replaced > 0 then
        util.notify(
          string.format("annotation saved, replacing %d overlapping (restore with :PunchlistUndo)", #replaced),
          vim.log.levels.WARN,
          { id = "punchlist_save" }
        )
      else
        util.notify("annotation saved", nil, { id = "punchlist_save" })
      end
    end,
    on_cancel = function()
      done()
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, saved_cursor)
      end
    end,
  })
end

--- Read-only hover showing the full annotation body under the cursor.
function M.peek_at_cursor()
  local _, rel_path, repo_root = synced_target()
  if not rel_path then
    return
  end
  local annotation = store.find_annotation_at_line(repo_root, rel_path, vim.fn.line("."))
  if not annotation then
    util.notify("no annotation on this line", vim.log.levels.WARN)
    return
  end
  local title = annotation.intent:upper()
  local lines = anchor.lines_reader(repo_root)(rel_path)
  local state = anchor.state(annotation, lines)
  local body = annotation.body
  if state ~= "ok" then
    title = title .. "  [" .. state:upper() .. "]"
    -- Drifted annotations are exactly when you need to know what the code looked
    -- like when the annotation was written, so show the stored anchor text
    -- alongside the body rather than making the user open the JSON.
    local was = annotation.anchor and annotation.anchor.text
    if was and was ~= "" then
      body = body .. "\n\nanchored to: " .. was
    end
  end
  float.peek({
    title = title,
    body = body,
    span = { start_line = annotation.start_line, end_line = annotation.end_line },
  })
end

--- Re-captures the anchor for the line annotation under the cursor and clears any
--- `orphaned` flag. Staleness is never auto-resolved -- this is the only way to
--- say "yes, I've looked, the annotation still applies to this code".
---
--- With a visual selection (or an Ex range) the annotation is also *retargeted*:
--- it moves onto the selected lines, which is how you rescue an annotation whose
--- code was rewritten somewhere else in the file. The selection must still
--- touch the annotation somewhere, so there's no ambiguity about which annotation is
--- being moved.
---
--- Nothing is written until the confirmation float is accepted, and the target
--- range is highlighted while it's open, so "where am I reanchoring to?" is
--- answered before the anchor changes.
---@param explicit_start? integer 1-indexed target start (Ex range)
---@param explicit_end? integer 1-indexed target end; defaults to `explicit_start`
function M.reanchor_at_cursor(explicit_start, explicit_end)
  local bufnr, rel_path, repo_root = synced_target()
  if not rel_path then
    return
  end

  -- A range means "retarget onto these lines"; no range means "re-hash where
  -- the annotation already is".
  local target_start, target_end
  if explicit_start then
    target_start, target_end = explicit_start, explicit_end or explicit_start
  elseif is_visual_mode() then
    target_start, target_end = visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end

  local annotation
  if target_start then
    annotation = store.find_annotation_in_range(repo_root, rel_path, target_start, target_end)
    if not annotation then
      util.notify("no annotation overlaps this selection", vim.log.levels.WARN)
      return
    end
  else
    annotation = store.find_annotation_at_line(repo_root, rel_path, vim.fn.line("."))
    if not annotation then
      util.notify("no annotation on this line", vim.log.levels.WARN)
      return
    end
  end

  local start_line = target_start or annotation.start_line
  local end_line = target_end or annotation.end_line
  local moved = start_line ~= annotation.start_line or end_line ~= annotation.end_line

  local captured = anchor.capture(bufnr, start_line, end_line)
  if not captured then
    -- Typical for an orphaned annotation pointing past the end of a shrunken
    -- file: there's nothing to hash, so say what to do about it.
    util.notify("range no longer exists -- select the code to reanchor to", vim.log.levels.WARN)
    return
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local state = anchor.state(annotation, buf_lines)

  local done, restore = stage_target(bufnr, start_line, end_line, #buf_lines)

  local was = annotation.anchor and annotation.anchor.text
  local lines = {
    "annotation: " .. util.truncate(util.first_line(annotation.body), REANCHOR_PREVIEW_MAX),
  }
  if moved then
    table.insert(
      lines,
      string.format(
        "moving:  %s \u{2192} %s",
        range_label(annotation.start_line, annotation.end_line),
        range_label(start_line, end_line)
      )
    )
  end
  table.insert(lines, "was:     " .. ((was and was ~= "") and was or "(no anchor)"))
  table.insert(lines, "now:     " .. util.truncate(buf_lines[start_line] or "", REANCHOR_PREVIEW_MAX))
  if not moved and state == "ok" then
    -- Nothing has drifted, so the anchor rewrite is a no-op. Say so instead of
    -- letting an identical was/now pair look like a bug.
    table.insert(lines, "(already up to date)")
  end

  float.confirm({
    title = string.format(
      "REANCHOR %s:%s%s",
      rel_path,
      range_label(start_line, end_line),
      state ~= "ok" and ("  [" .. state:upper() .. "]") or ""
    ),
    intent = annotation.intent,
    span = { start_line = start_line, end_line = end_line },
    lines = lines,
    footer = "<CR> reanchor  \u{b7}  q/<Esc> cancel",
    on_confirm = function()
      done()
      local position = moved and { start_line = start_line, end_line = end_line } or nil
      if not store.reanchor(repo_root, rel_path, annotation.id, captured, position) then
        -- The annotation was deleted (picker, another buffer) while the
        -- confirmation was open.
        util.notify("annotation no longer exists", vim.log.levels.WARN)
        return
      end
      -- A retarget invalidates the extmarks tracking the annotation's old
      -- position; they have to be rebuilt from the stored range. Deliberately
      -- `rebuild_path` and not `resync_path`: the latter syncs marks into the
      -- store first, which would write the old position back over the one we
      -- just stored and leave the annotation rendering [stale] forever.
      if moved then
        track.rebuild_path(repo_root, rel_path)
      end
      M.refresh(bufnr)
      util.notify(
        string.format("reanchored to %s:%s", rel_path, range_label(start_line, end_line)),
        nil,
        { id = "punchlist_reanchor" }
      )
    end,
    on_cancel = function()
      done()
      restore()
    end,
  })
end

--- Marks the annotation under the cursor as cut: it is *not* removed, it's just
--- recorded as the pending move (and flagged in the gutter) until
--- `paste_at_cursor` puts it somewhere. Cutting the same annotation again cancels.
---
--- Nothing is written to the store here, so an abandoned cut costs nothing.
function M.cut_at_cursor()
  local _, rel_path, repo_root = synced_target()
  if not rel_path then
    return
  end
  local annotation = store.find_annotation_at_line(repo_root, rel_path, vim.fn.line("."))
  if not annotation then
    util.notify("no annotation on this line", vim.log.levels.WARN)
    return
  end

  local cut = register.cut(repo_root, rel_path, annotation)
  -- `refresh_all`, not `refresh`: replacing or cancelling a cut has to drop the
  -- glyph from whatever file the *previous* cut was in, which may not be this
  -- buffer.
  M.refresh_all()
  if not cut then
    util.notify("cut cancelled", nil, { id = "punchlist_cut" })
    return
  end
  util.notify(
    string.format("cut: %s  (paste with :PunchlistPaste)", util.first_line(annotation.body)),
    nil,
    { id = "punchlist_cut" }
  )
end

--- Moves the cut annotation onto the cursor line, the visual selection, or an Ex
--- range -- in any file in the same repo.
---
--- This is the gesture the range form of reanchoring can't be: reanchoring
--- requires the target to overlap the annotation (so there's no guessing about
--- which annotation moved), which rules out "this belongs 200 lines down" and
--- "this belongs in another file entirely". Naming the annotation up front, with
--- `cut_at_cursor`, removes the ambiguity instead.
---
--- Like reanchoring, nothing is written until the confirmation float is
--- accepted, and the destination is highlighted while it's open. Cancelling
--- leaves the annotation cut, so a mis-aimed paste is one more `<CR>` away from
--- being right rather than needing a fresh cut.
---@param explicit_start? integer 1-indexed target start (Ex range)
---@param explicit_end? integer 1-indexed target end; defaults to `explicit_start`
function M.paste_at_cursor(explicit_start, explicit_end)
  local bufnr, rel_path, repo_root = synced_target()
  if not rel_path then
    util.notify("buffer has no file to paste into", vim.log.levels.WARN)
    return
  end

  local pending, reason = register.resolve()
  if not pending then
    util.notify(reason, vim.log.levels.WARN)
    return
  end
  -- Annotations live in a per-repo store, so a cross-repo move isn't a move at
  -- all. Keep the register loaded: the user probably wants to paste it back
  -- home, not start over.
  if pending.repo_root ~= repo_root then
    util.notify("the cut annotation belongs to another repo", vim.log.levels.WARN)
    return
  end

  local annotation = pending.annotation
  -- `synced_target()` only synced *this* buffer; the cut annotation may live in another
  -- one with unflushed drift, and both the "already there" check below and the
  -- confirmation's from-location read its stored position. Sync mutates the
  -- store's annotation tables in place, so `annotation` stays the right reference.
  if pending.rel_path ~= rel_path then
    track.sync_path(repo_root, pending.rel_path)
  end

  local start_line, end_line = target_range(explicit_start, explicit_end)
  if pending.rel_path == rel_path and start_line == annotation.start_line and end_line == annotation.end_line then
    util.notify("the cut annotation is already there", vim.log.levels.WARN)
    return
  end

  local captured = anchor.capture(bufnr, start_line, end_line)
  if not captured then
    util.notify("target range doesn't exist in this buffer", vim.log.levels.WARN)
    return
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Pastes never evict (see `store.move_annotation`), so an overlap is legal --
  -- but silently stacking two annotations on one range is worth a word, both here
  -- and after the fact.
  local occupant = store.find_annotation_in_range(repo_root, rel_path, start_line, end_line)
  if occupant and occupant.id == annotation.id then
    occupant = nil
  end

  local done, restore = stage_target(bufnr, start_line, end_line, #buf_lines)

  local was = annotation.anchor and annotation.anchor.text
  local lines = {
    "annotation: " .. util.truncate(util.first_line(annotation.body), REANCHOR_PREVIEW_MAX),
    string.format(
      "moving:  %s \u{2192} %s",
      util.location(pending.rel_path, annotation),
      rel_path .. ":" .. range_label(start_line, end_line)
    ),
    "was:     " .. ((was and was ~= "") and was or "(no anchor)"),
    "now:     " .. util.truncate(buf_lines[start_line] or "", REANCHOR_PREVIEW_MAX),
  }
  if occupant then
    table.insert(lines, "note:    overlaps " .. util.truncate(util.first_line(occupant.body), REANCHOR_PREVIEW_MAX))
  end

  float.confirm({
    title = string.format("MOVE \u{2192} %s:%s", rel_path, range_label(start_line, end_line)),
    intent = annotation.intent,
    span = { start_line = start_line, end_line = end_line },
    lines = lines,
    footer = "<CR> move  \u{b7}  q/<Esc> keep cut",
    on_confirm = function()
      done()
      local moved = store.move_by_id(
        repo_root,
        pending.rel_path,
        annotation.id,
        rel_path,
        { start_line = start_line, end_line = end_line },
        captured
      )
      if not moved then
        -- Deleted (picker, another buffer) while the confirmation was open.
        register.clear()
        util.notify("annotation no longer exists", vim.log.levels.WARN)
        M.refresh_all()
        return
      end
      register.clear()
      -- `rebuild_path`, not `resync_path`, on both ends: the store now holds the
      -- authoritative position, and syncing the old marks first would write
      -- the pre-move range straight back over it (the same trap the retarget
      -- path documents). The source was already synced above, so rebuilding
      -- its remaining marks from the store loses nothing.
      track.rebuild_path(repo_root, pending.rel_path)
      track.rebuild_path(repo_root, rel_path)
      M.refresh_all()
      util.notify(
        string.format(
          "moved to %s:%s%s",
          rel_path,
          range_label(start_line, end_line),
          occupant and "  (now overlapping an existing annotation)" or ""
        ),
        occupant and vim.log.levels.WARN or nil,
        { id = "punchlist_move" }
      )
    end,
    on_cancel = function()
      done()
      restore()
    end,
  })
end

--- Deletes the line annotation under the cursor, if any. Recoverable with
--- `restore_deleted()`.
function M.delete_at_cursor()
  local bufnr, rel_path, repo_root = synced_target()
  if not rel_path then
    return
  end
  local annotation = store.find_annotation_at_line(repo_root, rel_path, vim.fn.line("."))
  if not annotation then
    util.notify("no annotation on this line", vim.log.levels.WARN)
    return
  end

  -- By id, not position: `synced_target()` just synced, but ids are stable
  -- regardless.
  local removed = store.delete_by_id(repo_root, rel_path, annotation.id)
  if not removed then
    return
  end
  M.stash_deleted({ { repo_root = repo_root, rel_path = rel_path, annotation = removed } })
  track.resync_path(repo_root, rel_path)
  M.refresh(bufnr)
  util.notify(
    string.format("deleted: %s  (restore with :PunchlistUndo)", util.first_line(removed.body)),
    nil,
    { id = "punchlist_delete" }
  )
end

--- Moves the cursor to the next (`delta = 1`) or previous (`delta = -1`)
--- annotated line in the current buffer, wrapping around.
function M.jump(delta)
  local _, rel_path, repo_root = synced_target()
  if not rel_path then
    return
  end
  local lines = vim.iter(store.get_file_annotations(repo_root, rel_path))
    :map(function(annotation)
      return annotation.start_line
    end)
    :totable()
  table.sort(lines)
  if #lines == 0 then
    util.notify("no annotations in this file", vim.log.levels.WARN)
    return
  end

  local current = vim.fn.line(".")
  local target
  if delta > 0 then
    target = vim.iter(lines):find(function(l)
      return l > current
    end) or lines[1]
  else
    target = vim.iter(lines):rev():find(function(l)
      return l < current
    end) or lines[#lines]
  end

  -- Set the ' mark first so <C-o>/`` come back here, like every other
  -- jump-to-location motion.
  vim.cmd.normal({ "m'", bang = true })
  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

--- Opens the snacks picker over every annotation in the repo.
function M.list()
  return picker.list()
end

--- Compiles every annotation into a single prompt,
--- writes it to `<data_dir>/<prompt_file>` and shows it so you can
--- eyeball/tweak it before pasting.
function M.compile_prompt()
  local _, _, repo_root = synced_target()
  local text = prompt.compose(repo_root)
  if vim.trim(text) == "" then
    util.notify("no annotations to compile yet", vim.log.levels.WARN)
    return
  end

  vim.fn.mkdir(store.data_dir(repo_root), "p")
  local path = store.prompt_path(repo_root)
  if vim.fn.writefile(vim.split(text, "\n", { plain = true }), path) ~= 0 then
    util.notify("could not write " .. path, vim.log.levels.ERROR)
    return
  end

  Snacks.win({
    file = path,
    width = 0.8,
    height = 0.8,
    border = "rounded",
    title = " Review Prompt ",
    title_pos = "center",
    footer_keys = true,
    enter = true,
    wo = { wrap = true },
    -- `file =` loads the buffer via `bufadd`/`bufload`, which snacks marks
    -- `readonly`/non-`modifiable` on first load. Undo that so the prompt
    -- can be tweaked in place before `y` grabs the (possibly edited) text.
    bo = { modifiable = true, readonly = false },
    keys = {
      q = "close",
      yank = {
        "y",
        function(self)
          vim.fn.setreg("+", table.concat(self:lines(), "\n"))
          util.notify("prompt yanked")
        end,
        desc = "yank",
      },
      save = {
        "<C-s>",
        function()
          vim.cmd("silent! write")
        end,
        mode = { "n", "i" },
        desc = "save",
      },
      clear = {
        "c",
        function(self)
          self:close()
          M.clear_all()
        end,
        desc = "clear",
      },
    },
  })
  util.notify("prompt written to " .. path)
end

--- Clears every annotation for this repo.
function M.clear_all()
  local _, _, repo_root = synced_target()
  if vim.fn.confirm("Clear all punchlist annotations for this repo?", "&Yes\n&No", 2) ~= 1 then
    return
  end

  track.detach_all()
  register.clear()
  store.clear_all(repo_root)
  M.refresh_all()
  util.notify("all annotations cleared")
end

--- Call this from your Neovim config, e.g.:
---   require("punchlist").setup({})
--- Set `vim.g.maplocalleader` *before* calling setup() if you want the
--- default keymaps bound to a custom localleader.
function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then
    error("punchlist.nvim requires Neovim 0.11+")
  end
  if not pcall(require, "snacks") then
    error("punchlist.nvim requires folke/snacks.nvim")
  end

  config.setup(opts)
  signs.setup_highlights()
  require("punchlist.commands").setup(M)

  -- Buffers that were already loaded when setup() ran (a session restore, or
  -- `require("punchlist").setup()` from a lazy `config`) never see
  -- BufReadPost, so bring them up to date now.
  util.loaded_bufs():each(function(bufnr)
    track.ensure_attached(bufnr)
    M.refresh(bufnr)
  end)
end

return M
