-- Drift detection: has the code an annotation was attached to changed since the
-- annotation was written?
--
-- An annotation stores an `anchor` -- a hash of the lines it covered plus the first
-- of those lines as human-readable context -- captured at annotation write time.
-- Comparing that hash against the file's current contents classifies the
-- annotation as:
--
--   "ok"       - the code is as it was; the annotation still makes sense
--   "stale"    - those lines still exist but their content changed
--   "orphaned" - the range is gone entirely (file truncated, lines deleted)
--
-- Note that this is only one half of position tracking. `track.lua` keeps
-- positions correct within a live session via extmarks; here we worry about
-- hashing so we can reconsititute a set of annotations in a new nvim session
-- or after the annotations.json has been modified externally.
--
-- When an annotation is created or its range is re-selected, here's the pseudocode
-- for what happens:
--
--   anchor = capture(bufnr, start_line, end_line)
--          = { hash = sha256(lines[start..end])[1..16],
--              text = truncate(lines[start]) }
--   store the anchor alongside the annotation body
--
-- When an annotation is rendered or exported, callers that touch many annotations
-- build one reader and reuse it, so each file is read once. Pseudocode:
--
--   lines_for = lines_reader(repo_root)          -- memoised per rel_path
--   for each annotation:
--     state = state(annotation, lines_for(annotation.rel_path))
--     -- "ok" when line_tracking is off or the file is unreadable
--     render/annotate according to state
--

local config = require("punchlist.config")
local util = require("punchlist.util")

local M = {}

local ANCHOR_TEXT_MAX = 80

--- sha256 of `lines` joined with "\n", truncated to 16 hex chars.
function M.hash_lines(lines)
  return vim.fn.sha256(table.concat(lines, "\n")):sub(1, 16)
end

-- Hash and initial text of a line range; nil if the buffer isn't loaded/valid
-- or the range is out of bounds.
function M.capture(bufnr, s, e)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  if s < 1 or e < s or e > count then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  return { hash = M.hash_lines(lines), text = util.truncate(lines[1] or "", ANCHOR_TEXT_MAX) }
end

--- The raw comparison of a stored annotation against `lines`, reporting:
---   "orphaned" -- annotation.orphaned is set, or its range no longer exists
---   "stale"    -- the range exists but its content no longer hashes the same
---   "ok"       -- content matches, there's no anchor to compare, or there's
---                 nothing to compare
---
--- Callers usually want `M.state`, which layers config and unreadable files on
--- top of this.
function M.compare(annotation, lines)
  if annotation.orphaned then
    return "orphaned"
  end
  if not annotation.anchor then
    return "ok"
  end
  local s, e = annotation.start_line, annotation.end_line
  if s < 1 or e < s or s > #lines then
    return "orphaned"
  end
  local slice = vim.list_slice(lines, s, math.min(e, #lines))
  if M.hash_lines(slice) ~= annotation.anchor.hash then
    return "stale"
  end
  return "ok"
end

--- Drift state of `annotation`: `M.compare`, but honouring
--- `config.line_tracking` and unreadable files (both collapse to "ok") so
--- callers don't have to decide that themselves. `lines` is whatever
--- `lines_reader(repo_root)(rel_path)` returned (may be nil).
---
--- This is the one every renderer/exporter should call.
function M.state(annotation, lines)
  if not config.options.line_tracking or not lines then
    return "ok"
  end
  return M.compare(annotation, lines)
end

--- Current lines of `rel_path` under `repo_root`: from the live buffer if one
--- is loaded (so **unsaved edits are considered**), otherwise read from disk.
--- Returns nil if neither is available (e.g. the file was deleted).
function M.file_lines(repo_root, rel_path)
  local path = vim.fs.joinpath(repo_root, rel_path)

  local bufnr = util.buf_for_path(path)
  if bufnr then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines
end

--- Each file is read at most once per reader no matter how many annotations
--- reference it. Failures are cached too. Readers are intended to be
--- short-lived (one render pass) since a longer-lived cache would hide the
--- live edits we're trying to detect
function M.lines_reader(repo_root)
  local cache = {}
  return function(rel_path)
    if not config.options.line_tracking then
      return nil
    end
    if cache[rel_path] == nil then
      cache[rel_path] = M.file_lines(repo_root, rel_path) or false
    end
    return cache[rel_path] or nil
  end
end

return M
