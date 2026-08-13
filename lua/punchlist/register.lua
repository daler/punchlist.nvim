-- One-slot "cut register" for moving an annotation somewhere else.
--
-- Modelled on vim's own `d`/`p` rather than on drag-and-drop: cutting records
-- *which* annotation is being moved and nothing else, and the store is only
-- touched when a paste is confirmed. So an abandoned cut is a no-op -- the
-- annotation stays exactly where it was, still rendered, still in the prompt.
--
-- The slot holds identity (repo_root, rel_path, id), never a copy of the
-- annotation: `resolve()` re-reads it from the store at paste time, so a body
-- edit, a delete, or an external rewrite of annotations.json between cut and
-- paste can't paste stale content back into the file.
--
-- Session-only by design. A cut that outlived a Neovim restart would be a
-- pending mutation with no visible owner.

local store = require("punchlist.store")
local util = require("punchlist.util")

local M = {}

---@type { repo_root: string, rel_path: string, id: integer }?
local slot = nil

--- Marks `annotation` (in `rel_path` under `repo_root`) as the pending move.
--- Cutting the annotation that's already cut clears the slot instead, so the
--- gesture toggles.
---@return boolean cut true if the slot now holds an annotation, false if cleared
function M.cut(repo_root, rel_path, annotation)
  if slot and slot.repo_root == repo_root and slot.rel_path == rel_path and slot.id == annotation.id then
    slot = nil
    return false
  end
  slot = { repo_root = repo_root, rel_path = rel_path, id = annotation.id }
  return true
end

function M.clear()
  slot = nil
end

--- The pending cut, re-resolved against the store.
---
--- Returns nil when nothing is cut, or when the cut annotation has since
--- disappeared -- in which case the slot is dropped and `reason` says which,
--- so callers can report it rather than silently doing nothing.
---@return { repo_root: string, rel_path: string, annotation: table }? pending, string? reason
function M.resolve()
  if not slot then
    return nil, "nothing cut -- use :PunchlistCut on an annotation first"
  end
  local annotation = store.get_by_id(slot.repo_root, slot.rel_path, slot.id)
  if not annotation then
    slot = nil
    return nil, "the cut annotation no longer exists"
  end
  return { repo_root = slot.repo_root, rel_path = slot.rel_path, annotation = annotation }
end

--- Id of the pending cut *if* it lives in `bufnr`'s file, so `signs.render`
--- can mark it in the gutter. Nil-checks the slot first: with no cut pending
--- (the common case) this costs nothing.
---@return integer?
function M.pending_id(bufnr)
  if not slot then
    return nil
  end
  local rel_path, repo_root = util.relative_path(bufnr)
  if rel_path ~= slot.rel_path or repo_root ~= slot.repo_root then
    return nil
  end
  return slot.id
end

return M
