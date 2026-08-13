-- Headless test harness for util/store/anchor/track. These modules are
-- pure-ish and buffer-level, so they're testable without any UI or real
-- snacks.nvim install.
--
-- Run with (from the plugin root, the parent of lua/):
--   nvim --headless -u lua/tests/minimal.lua
--
-- Exits with status 0 on success, 1 if any assertion failed.

-- This file lives at <plugin_root>/lua/tests/minimal.lua; the rtp entry
-- modules resolve against is <plugin_root> (two levels up).
local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>"), ":p:h:h:h")
vim.opt.rtp:prepend(root)

-- store/util only touch Snacks for notifications now that repo-root discovery
-- uses vim.fs.root; stub it so this runs without snacks.nvim installed.
_G.Snacks = {
  notify = function() end,
}

local failures = {}
local checks = 0

local function ok(cond, msg)
  checks = checks + 1
  if not cond then
    table.insert(failures, msg or ("check #" .. checks .. " failed"))
  end
end

local function eq(a, b, msg)
  ok(a == b, string.format("%s: expected %s, got %s", msg or "eq", vim.inspect(b), vim.inspect(a)))
end

local store = require("punchlist.store")
local anchor = require("punchlist.anchor")
local track = require("punchlist.track")
local util = require("punchlist.util")
local config = require("punchlist.config")
config.setup({})

-- A scratch repo root + a real file on disk, since anchor.file_lines() and
-- store.save() touch the filesystem.
local repo_root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(repo_root, "p")
local rel_path = "example.lua"
local abs_path = vim.fs.joinpath(repo_root, rel_path)

local function write_file(lines)
  vim.fn.writefile(lines, abs_path)
end

local initial_lines = {}
for i = 1, 100 do
  initial_lines[i] = "line " .. i
end
write_file(initial_lines)

local bufnr = vim.fn.bufadd(abs_path)
vim.fn.bufload(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)

---------------------------------------------------------------------------
-- util
---------------------------------------------------------------------------

do
  eq(util.truncate("abcdef", 10), "abcdef", "truncate leaves short strings alone")
  eq(util.truncate("abcdef", 4), "abc\u{2026}", "truncate cuts to max chars with an ellipsis")
  -- Byte-based truncation used to slice this mid-codepoint.
  local wide = string.rep("\u{4f60}", 8)
  local cut = util.truncate(wide, 4)
  eq(vim.fn.strchars(cut), 4, "truncate counts characters, not bytes")
  ok(vim.fn.strchars(cut) * 3 < #wide, "multibyte truncation is not byte-sliced")

  eq(util.first_line("one\ntwo"), "one", "first_line stops at the newline")
  eq(util.first_line(""), "", "first_line of an empty body")

  eq(util.location(rel_path, { start_line = 3, end_line = 3 }), rel_path .. ":3", "location for a single line")
  eq(util.location(rel_path, { start_line = 3, end_line = 5 }), rel_path .. ":3-5", "location for a range")

  local rel, root = util.relative_path(bufnr, repo_root)
  eq(rel, rel_path, "relative_path against an explicit root")
  eq(root, repo_root, "relative_path echoes the root it was given")

  -- A buffer outside the given root is not part of that repo, and must report
  -- nil rather than a garbage suffix of its absolute path.
  local outside = vim.fn.bufadd(vim.fs.joinpath(vim.fs.normalize(vim.fn.tempname()), "elsewhere.lua"))
  eq(util.relative_path(outside, repo_root), nil, "relative_path rejects files outside the root")
end

---------------------------------------------------------------------------
-- store: schema defaults
---------------------------------------------------------------------------

do
  local data = store.load(repo_root)
  eq(data.next_id, 1, "fresh store next_id")
end

---------------------------------------------------------------------------
-- store: upsert allocates ids, preserves id on edit, explicit id on restore
---------------------------------------------------------------------------

do
  local a1 = anchor.capture(bufnr, 50, 50)
  ok(a1 ~= nil, "capture on a loaded in-range line returns an anchor")

  store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 50, intent = "fix", body = "first body", anchor = a1 })
  local c = store.find_annotation_at_line(repo_root, rel_path, 50)
  ok(c ~= nil, "annotation stored")
  ok(c.id ~= nil, "annotation got an id")
  local first_id = c.id

  -- Editing the same range should keep its id and update the anchor.
  local a2 = anchor.capture(bufnr, 50, 50)
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 50, intent = "fix", body = "edited body", anchor = a2 })
  local c2 = store.find_annotation_at_line(repo_root, rel_path, 50)
  eq(c2.id, first_id, "editing an overlapping annotation preserves its id")
  eq(c2.body, "edited body", "editing an overlapping annotation replaces the body")

  -- Deleting it (empty body) removes it.
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 50, intent = "fix", body = "" })
  ok(store.find_annotation_at_line(repo_root, rel_path, 50) == nil, "empty body deletes the annotation")

  -- Restoring with an id brings back the same identity.
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 50, intent = "fix", body = "restored body", anchor = a2, id = first_id })
  local c3 = store.find_annotation_at_line(repo_root, rel_path, 50)
  eq(c3.id, first_id, "restore_deleted's id is honored")

  -- An edit that inherits an id isn't a replacement, so there's nothing to undo.
  local replaced = store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 50, intent = "fix", body = "another edit", anchor = a2 })
  eq(#replaced, 0, "editing in place reports no replaced annotations")

  -- A range annotation swallowing two separate annotations reports both.
  store.clear_all(repo_root)
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 10, end_line = 10, intent = "fix", body = "one" })
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 20, end_line = 20, intent = "fix", body = "two" })
  replaced = store.upsert_line_annotation(repo_root, rel_path, { start_line = 5, end_line = 25, intent = "fix", body = "covers both" })
  eq(#replaced, 2, "an overlapping range reports every annotation it replaced")
  eq(#store.get_file_annotations(repo_root, rel_path), 1, "only the new annotation survives")
end

---------------------------------------------------------------------------
-- store: delete by id, prune, persistence, external change
---------------------------------------------------------------------------

do
  store.clear_all(repo_root)
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 7, end_line = 7, intent = "discuss", body = "by id" })
  local annotation = store.find_annotation_at_line(repo_root, rel_path, 7)

  eq(store.delete_by_id(repo_root, rel_path, 9999), nil, "delete_by_id on an unknown id is a no-op")
  local removed = store.delete_by_id(repo_root, rel_path, annotation.id)
  ok(removed ~= nil, "delete_by_id returns the removed annotation")
  eq(removed.body, "by id", "the removed annotation is the one asked for")
  eq(#store.all_files(repo_root), 0, "files with no annotations left are pruned")

  -- Round-trip through disk: the pretty-printed json must decode back.
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 3, end_line = 4, intent = "fix", body = "line one\nline two", anchor = { hash = "abc", text = "x" } })
  local raw = table.concat(vim.fn.readfile(store.annotations_path(repo_root)), "\n")
  ok(#vim.split(raw, "\n", { plain = true }) > 1, "the store is written multi-line, not minified")
  local decoded = vim.json.decode(raw)
  eq(decoded.files[rel_path][1].body, "line one\nline two", "embedded newlines survive the round trip")

  -- An external rewrite of annotations.json must be picked up, not masked by the
  -- in-memory cache.
  decoded.files[rel_path][1].body = "rewritten externally"
  -- Sleep past the 1s mtime granularity some filesystems have.
  vim.uv.sleep(1100)
  vim.fn.writefile(vim.split(vim.json.encode(decoded), "\n", { plain = true }), store.annotations_path(repo_root))
  eq(
    store.find_annotation_at_line(repo_root, rel_path, 3).body,
    "rewritten externally",
    "an external write to annotations.json is re-read"
  )
end

---------------------------------------------------------------------------
-- store: hand-written stores get ids allocated
---------------------------------------------------------------------------

do
  local handwritten = {
    files = {
      [rel_path] = {
        { kind = "line", start_line = 1, end_line = 1, intent = "fix", body = "no id here" },
        { kind = "line", start_line = 2, end_line = 2, intent = "fix", body = "nor here" },
      },
    },
  }
  local other_root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(vim.fs.joinpath(other_root, config.options.data_dir), "p")
  vim.fn.writefile(vim.split(vim.json.encode(handwritten), "\n", { plain = true }), store.annotations_path(other_root))

  local data = store.load(other_root)
  local annotations = store.get_file_annotations(other_root, rel_path)
  ok(annotations[1].id ~= nil and annotations[2].id ~= nil, "normalize allocates missing ids")
  ok(annotations[1].id ~= annotations[2].id, "allocated ids are distinct")
  ok(data.next_id > math.max(annotations[1].id, annotations[2].id), "next_id is ahead of every allocated id")
  vim.fn.delete(other_root, "rf")
end

---------------------------------------------------------------------------
-- anchor: ok / stale / orphaned
---------------------------------------------------------------------------

do
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local a = anchor.capture(bufnr, 10, 10)
  local annotation = { start_line = 10, end_line = 10, anchor = a }
  eq(anchor.state(annotation, lines), "ok", "anchor.state matches unchanged content")

  local changed = vim.deepcopy(lines)
  changed[10] = "line 10 -- edited"
  eq(anchor.state(annotation, changed), "stale", "anchor.state flags edited content")

  local truncated = {}
  for i = 1, 5 do
    truncated[i] = lines[i]
  end
  eq(anchor.state(annotation, truncated), "orphaned", "anchor.state flags a range past EOF")

  local no_anchor = { start_line = 10, end_line = 10 }
  eq(anchor.state(no_anchor, lines), "ok", "anchor.state on a nil anchor is ok (nothing to compare)")

  local flagged = { start_line = 10, end_line = 10, anchor = a, orphaned = true }
  eq(anchor.state(flagged, lines), "orphaned", "anchor.state respects annotation.orphaned")
end

---------------------------------------------------------------------------
-- track: extmarks correct positions across an edit elsewhere in the buffer
---------------------------------------------------------------------------

do
  store.clear_all(repo_root)
  local a = anchor.capture(bufnr, 50, 52)
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 50, end_line = 52, intent = "fix", body = "tracked annotation", anchor = a })
  local before = store.find_annotation_at_line(repo_root, rel_path, 50)
  local id = before.id

  track.resync(bufnr)

  -- Insert 10 lines above the annotated range.
  local extra = {}
  for i = 1, 10 do
    extra[i] = "inserted " .. i
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, extra)

  track.sync(bufnr)
  local after = store.find_annotation_at_line(repo_root, rel_path, 60)
  ok(after ~= nil, "annotation found at its corrected position")
  if after then
    eq(after.id, id, "corrected annotation kept its id")
    eq(after.start_line, 60, "start_line shifted by the inserted lines")
    eq(after.end_line, 62, "end_line shifted by the inserted lines")
    eq(anchor.state(after, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), "ok", "shifted annotation is not stale")
  end

  -- Undo the insert, sync again: position should correct back.
  vim.api.nvim_buf_set_lines(bufnr, 0, 10, false, {})
  track.sync(bufnr)
  local restored = store.find_annotation_at_line(repo_root, rel_path, 50)
  ok(restored ~= nil, "annotation position corrects back after the insert is removed")
end

---------------------------------------------------------------------------
-- track: deleting the annotated lines orphans (never deletes) the annotation
---------------------------------------------------------------------------

do
  track.resync(bufnr)
  local before = store.find_annotation_at_line(repo_root, rel_path, 50)
  ok(before ~= nil and not before.orphaned, "annotation present and not orphaned before deletion")

  vim.api.nvim_buf_set_lines(bufnr, 49, 52, false, {})
  track.sync(bufnr)

  local annotations = store.get_file_annotations(repo_root, rel_path)
  ok(#annotations == 1, "annotation still exists after its lines were deleted")
  ok(annotations[1].orphaned == true, "annotation is flagged orphaned")
end

---------------------------------------------------------------------------
-- track: undoing that deletion un-orphans the annotation
---------------------------------------------------------------------------

do
  -- Real undo, not another set_lines: `invalidate = true` marks are *hidden*
  -- rather than deleted, and it's undo specifically that brings them back.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent undo")
  end)
  track.sync(bufnr)

  local annotations = store.get_file_annotations(repo_root, rel_path)
  eq(#annotations, 1, "annotation still exists after the deletion was undone")
  ok(not annotations[1].orphaned, "annotation is no longer flagged orphaned after undo")
  eq(annotations[1].start_line, 50, "annotation is back at its original position")
  eq(
    anchor.state(annotations[1], vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
    "ok",
    "restored annotation is neither orphaned nor stale"
  )
end

---------------------------------------------------------------------------
-- track: ensure_attached() must not rebuild an attached buffer
---------------------------------------------------------------------------

do
  -- Drop the previous block's (now invalid) marks first: clear_all restarts id
  -- allocation from 1, so a leftover extmark could otherwise be mistaken for
  -- the new annotation's.
  track.detach(bufnr)
  store.clear_all(repo_root)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)
  store.upsert_line_annotation(repo_root, rel_path, {
    start_line = 50,
    end_line = 50,
    intent = "fix",
    body = "drift survivor",
    anchor = anchor.capture(bufnr, 50, 50),
  })
  track.resync(bufnr)

  -- Edit above the annotation and *don't* sync, the way `:split` (BufWinEnter with
  -- no preceding BufLeave) leaves things.
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted a", "inserted b" })
  track.ensure_attached(bufnr)
  track.sync(bufnr)

  local annotation = store.find_annotation_at_line(repo_root, rel_path, 52)
  ok(annotation ~= nil, "ensure_attached() on an attached buffer keeps unsynced drift")
  if annotation then
    eq(annotation.start_line, 52, "drift was preserved rather than rebuilt from the store")
  end
end

---------------------------------------------------------------------------
-- store: move_annotation
---------------------------------------------------------------------------

do
  local other_path = "other.lua"
  store.clear_all(repo_root)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)
  store.upsert_line_annotation(repo_root, rel_path, {
    start_line = 50,
    end_line = 52,
    intent = "fix",
    body = "movable",
    anchor = anchor.capture(bufnr, 50, 52),
  })
  local original = store.find_annotation_at_line(repo_root, rel_path, 50)
  local id = original.id
  -- Something else at the destination, to prove a move doesn't evict it.
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 11, end_line = 11, intent = "discuss", body = "sitting there" })

  eq(
    store.move_by_id(repo_root, rel_path, 9999, rel_path, { start_line = 1, end_line = 1 }, { hash = "x", text = "" }),
    nil,
    "move_annotation on an unknown id is a no-op"
  )

  -- Same file, non-overlapping destination: the case the range form of
  -- reanchoring can't express.
  local captured = anchor.capture(bufnr, 10, 12)
  local moved = store.move_by_id(repo_root, rel_path, id, rel_path, { start_line = 10, end_line = 12 }, captured)
  ok(moved ~= nil, "move_annotation returns the moved annotation")
  eq(moved.id, id, "a move preserves the annotation id")
  eq(moved.start_line, 10, "moved start_line")
  eq(moved.end_line, 12, "moved end_line")
  eq(moved.anchor.hash, captured.hash, "a move re-anchors to the destination")
  eq(anchor.state(moved, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), "ok", "a moved annotation is not stale")
  eq(#store.get_file_annotations(repo_root, rel_path), 2, "a move does not evict the annotation it overlaps")
  ok(store.find_annotation_at_line(repo_root, rel_path, 11) ~= nil, "the overlapped annotation is still there")
  eq(store.get_file_annotations(repo_root, rel_path)[1].start_line, 10, "the destination list stays sorted")

  -- Orphaned flags are cleared: a move is a deliberate statement about where
  -- the annotation belongs.
  store.mark_orphaned(repo_root, rel_path, id)
  eq(store.get_by_id(repo_root, rel_path, id).orphaned, true, "orphaned flag set for the cross-file case")

  -- Cross-file: the source file is pruned once its last annotation leaves.
  store.delete_by_id(repo_root, rel_path, store.find_annotation_at_line(repo_root, rel_path, 11).id)
  moved = store.move_by_id(repo_root, rel_path, id, other_path, { start_line = 3, end_line = 3 }, captured)
  ok(moved ~= nil, "an annotation can move to another file")
  eq(moved.orphaned, nil, "a move clears the orphaned flag")
  eq(store.get_by_id(repo_root, rel_path, id), nil, "the annotation is gone from the source file")
  eq(store.get_by_id(repo_root, other_path, id).body, "movable", "the annotation arrived in the destination file")
  eq(#store.all_files(repo_root), 1, "an emptied source file is pruned")
end

---------------------------------------------------------------------------
-- register: the one-slot cut register
---------------------------------------------------------------------------

do
  local register = require("punchlist.register")
  store.clear_all(repo_root)
  register.clear()
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 20, end_line = 20, intent = "fix", body = "cut me" })
  local annotation = store.find_annotation_at_line(repo_root, rel_path, 20)

  eq(register.resolve(), nil, "resolve with nothing cut")
  eq(register.pending_id(bufnr), nil, "pending_id with nothing cut")

  eq(register.cut(repo_root, rel_path, annotation), true, "cutting reports the slot as loaded")
  local pending = register.resolve()
  ok(pending ~= nil, "resolve returns the cut annotation")
  eq(pending.annotation.id, annotation.id, "resolve returns the right annotation")

  -- The buffer's own root resolution has to agree with what was cut, or the
  -- gutter would never mark it.
  local buf_rel, buf_root = util.relative_path(bufnr)
  if buf_rel == rel_path and buf_root == repo_root then
    eq(register.pending_id(bufnr), annotation.id, "pending_id marks the cut annotation in its own file")
  end

  -- Cutting the same annotation twice is a toggle, not a re-cut.
  eq(register.cut(repo_root, rel_path, annotation), false, "cutting the cut annotation clears the slot")
  eq(register.resolve(), nil, "the slot is empty after the toggle")

  -- The slot holds identity, not a copy: a body edit between cut and paste is
  -- visible, and a delete invalidates the cut instead of resurrecting it.
  register.cut(repo_root, rel_path, annotation)
  store.upsert_line_annotation(repo_root, rel_path, { start_line = 20, end_line = 20, intent = "fix", body = "edited after the cut" })
  eq(register.resolve().annotation.body, "edited after the cut", "resolve re-reads the body from the store")
  store.delete_by_id(repo_root, rel_path, annotation.id)
  local gone, reason = register.resolve()
  eq(gone, nil, "resolve drops a cut whose annotation was deleted")
  ok(reason ~= nil and reason:find("no longer exists") ~= nil, "resolve explains why the cut is void")
  eq(register.pending_id(bufnr), nil, "a voided cut leaves nothing in the gutter")
end

---------------------------------------------------------------------------
-- line_tracking = false: no-ops
---------------------------------------------------------------------------

do
  config.options.line_tracking = false
  track.detach(bufnr)
  track.resync(bufnr)
  eq(track.sync(bufnr), false, "track.sync is a no-op when line_tracking is disabled")
  config.options.line_tracking = true
end

---------------------------------------------------------------------------

vim.fn.delete(repo_root, "rf")

if #failures > 0 then
  io.stderr:write(string.format("%d/%d checks failed:\n", #failures, checks))
  for _, f in ipairs(failures) do
    io.stderr:write("  - " .. f .. "\n")
  end
  vim.cmd("cquit 1")
else
  print(string.format("all %d checks passed", checks))
  vim.cmd("qall!")
end
