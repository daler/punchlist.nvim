-- Extmark-based position tracking.
--
-- Each tracked annotation gets exactly one extmark whose **id is the annotation id**
--
-- Per-buffer context lives in `vim.b[bufnr].punchlist_ctx`, which dies with
-- the buffer

local store = require("punchlist.store")
local util = require("punchlist.util")
local config = require("punchlist.config")

local M = {}

local track_ns = vim.api.nvim_create_namespace("punchlist_track")

-- Buffers that currently have marks placed. Only used to answer "is this
-- already attached?" and to enumerate buffers worth syncing on exit.
---@type table<integer, true>
local attached = {}

-- Ids we flagged orphaned from *this* buffer's current set of marks, i.e.
-- ranges we watched get deleted. Undo un-invalidates such a mark, and this is
-- what lets `sync` tell that case apart from an annotation that was already
-- orphaned in the store when we attached (whose mark, placed at a last-known
-- position that happens to still exist, is valid but proves nothing).
---@type table<integer, table<integer, true>>
local orphaned_here = {}

---@return string? rel_path, string? repo_root
local function buf_paths(bufnr)
  local ctx = vim.b[bufnr].punchlist_ctx
  if not ctx then
    return nil, nil
  end
  return ctx[1], ctx[2]
end

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, track_ns, 0, -1)
  end
  attached[bufnr] = nil
  orphaned_here[bufnr] = nil
end

--- (Re)creates every tracking extmark for `bufnr` from what's currently in
--- the store.
---
--- Callers must have flushed any pending drift first (see `M.resync`):
--- rebuilding from the store discards whatever the old marks knew.
local function attach(bufnr)
  if not config.options.line_tracking then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) or not util.is_file_buf(bufnr) then
    vim.b[bufnr].punchlist_ctx = nil
    return
  end

  local rel_path, repo_root = util.relative_path(bufnr)
  if not rel_path then
    vim.b[bufnr].punchlist_ctx = nil
    return
  end
  vim.b[bufnr].punchlist_ctx = { rel_path, repo_root }

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, annotation in ipairs(store.get_file_annotations(repo_root, rel_path)) do
    if annotation.kind == "line" and annotation.id and annotation.start_line >= 1 and annotation.start_line <= line_count then
      local end_row = math.min(annotation.end_line, line_count) - 1
      local end_line_text = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(bufnr, track_ns, annotation.start_line - 1, 0, {
        id = annotation.id, -- the extmark *is* the annotation
        end_row = end_row,
        end_col = #end_line_text,
        right_gravity = false, -- text inserted at the start stays outside the range
        end_right_gravity = true, -- text appended at the end is absorbed into it
        invalidate = true, -- goes invalid (not deleted) if the range is removed
      })
    end
  end
  attached[bufnr] = true
  orphaned_here[bufnr] = {}
end

--- Writes current extmark positions for `bufnr` back into the store.
---
--- Annotations that moved get `store.update_position`.
--- Annotations whose range was deleted entirely get `store.mark_orphaned` (never
--- deleted); if such a range reappears (undo), the flag is cleared again.
---
--- Saves at most once. Returns whether anything changed.
function M.sync(bufnr)
  if not config.options.line_tracking then
    return false
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if not attached[bufnr] then
    return false
  end
  local rel_path, repo_root = buf_paths(bufnr)
  if not rel_path or not repo_root then
    return false
  end

  -- Snapshot the ids first: `store.update_position` re-sorts the very list
  -- `get_file_annotations` returns, which would corrupt an in-flight ipairs.
  local ids = vim.tbl_map(function(annotation)
    return annotation.id
  end, store.get_file_annotations(repo_root, rel_path))

  local changed = false
  local seen_orphaned = orphaned_here[bufnr] or {}
  for _, id in ipairs(ids) do
    -- Single return value: {} for an id we never placed (an annotation added since
    -- the last attach -- not our business), otherwise {row, col, details}.
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, id, { details = true })
    local row, details = mark[1], mark[3] or {}
    if row then
      if details.invalid then
        -- `invalidate = true` hides rather than deletes the mark when its whole
        -- range is removed, which is what distinguishes "range deleted" from
        -- "never tracked".
        changed = store.mark_orphaned(repo_root, rel_path, id) or changed
        seen_orphaned[id] = true
      else
        local start_line = row + 1
        local end_line = math.max(start_line, (details.end_row or row) + 1)
        changed = store.update_position(repo_root, rel_path, id, start_line, end_line) or changed
        if seen_orphaned[id] then
          -- The range we saw deleted is back (undo), so the mark is live again.
          changed = store.clear_orphaned(repo_root, rel_path, id) or changed
          seen_orphaned[id] = nil
        end
      end
    end
  end

  if changed then
    store.save(repo_root)
  end
  return changed
end

--- Clears every tracking extmark + per-buffer context for `bufnr`.
function M.detach(bufnr)
  clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].punchlist_ctx = nil
  end
end

--- Clears tracking for every buffer that currently has any (used by
--- `clear_all()`, since every annotation in every file is about to disappear).
function M.detach_all()
  for bufnr in pairs(attached) do
    M.detach(bufnr)
  end
end

--- Attaches tracking to `bufnr` unless it already has marks.
---
--- This is what the autocmds use. It deliberately does *not* rebuild an
--- already-attached buffer: `BufWinEnter` fires on things like `:split`, with
--- no preceding `BufLeave` to sync, so rebuilding there would throw away any
--- drift accumulated since the last sync.
function M.ensure_attached(bufnr)
  if not attached[bufnr] then
    attach(bufnr)
  end
end

--- Rebuilds marks after the *store* changed (add/delete/restore), flushing
--- current positions into the store first so nothing is lost.
function M.resync(bufnr)
  M.sync(bufnr)
  clear(bufnr)
  attach(bufnr)
end

--- Rebuilds marks *without* syncing first -- for when the existing marks are
--- known to be worthless: the buffer changed out from under us (external
--- reload), or the store already holds the authoritative position (a retarget
--- or move). Syncing here would write the old position back over the new one.
function M.rebuild(bufnr)
  clear(bufnr)
  attach(bufnr)
end

--- `resync()`, but resolved by (repo_root, rel_path) instead of a bufnr --
--- for actions (restore, picker delete) that may touch a file other than
--- the current buffer. No-op if that file isn't loaded.
function M.resync_path(repo_root, rel_path)
  local bufnr = util.buf_for_path(vim.fs.joinpath(repo_root, rel_path))
  if bufnr then
    M.resync(bufnr)
  end
end

--- `sync()`, but resolved by (repo_root, rel_path) -- for actions that need
--- another file's stored positions to be current before they read them (the
--- paste target may be in a different buffer than the cut annotation). No-op if
--- that file isn't loaded.
function M.sync_path(repo_root, rel_path)
  local bufnr = util.buf_for_path(vim.fs.joinpath(repo_root, rel_path))
  if bufnr then
    M.sync(bufnr)
  end
end

--- `rebuild()`, but resolved by (repo_root, rel_path) -- for actions that have
--- just written an *authoritative* position into the store (retargeting an
--- annotation onto a new range). The existing marks describe where the annotation
--- used to be, so syncing them first (as `resync_path` does) would write that
--- stale position straight back over the new one. No-op if the file isn't
--- loaded.
function M.rebuild_path(repo_root, rel_path)
  local bufnr = util.buf_for_path(vim.fs.joinpath(repo_root, rel_path))
  if bufnr then
    M.rebuild(bufnr)
  end
end

--- `sync()` on every buffer that currently has tracking attached. Used on
--- `VimLeavePre`.
function M.sync_all()
  for bufnr in pairs(attached) do
    M.sync(bufnr)
  end
end

return M
