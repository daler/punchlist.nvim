-- On-disk/in-memory schema, and utility functions for working with it, writing
-- to disk, querying it by line number, setting/removing states (stale and orphaned)
--
--   { next_id = integer,                             -- for allocating annotation.id
--     files = { [rel_path] = { annotation, ... } } }
-- Each annotation:
--   { id, kind = "line", start_line, end_line, intent, body,
--     anchor = { hash, text }?, orphaned = true? }        -- 1-indexed, inclusive
--
-- `id` is a stable identity independent of position, allocated from
-- `next_id`. Consider it a primary key: it is also the extmark id `track.lua`
-- uses, and what `delete_by_id` addresses annotations with.
--
-- `anchor` is a content hash (+ first line of text) captured when
-- the annotation was written
--
-- `anchor.lua` compares it against current buffer content to flag
-- `stale`/`orphaned` drift, see that file for more.
--
-- `track.lua` keeps start_line/end_line correct across in-session edits via
-- extmarks, see that file for more.
--
-- Here's an example with a single annotation:
--
-- {
--   "files": {
--     "path/to/file.lua": [
--       {
--         "anchor": {
--           "hash": "e93eae2ac34a9abe",
--           "text": ""
--         },
--         "body": "explain these lines",
--         "end_line": 38,
--         "id": 1,
--         "intent": "discuss",
--         "kind": "line",
--         "start_line": 19
--       }
--     ]
--   },
--   "next_id": 2
-- }

local config = require("punchlist.config")
local util = require("punchlist.util")

local M = {}

-- In-memory cache keyed by repo root so multiple buffers in the same repo
-- share one loaded table instead of hitting disk on every keystroke.
--
---@type table<string, { data: table, mtime: number?, dirty: boolean? }>
local cache = {}

function M.data_dir(repo_root)
  return vim.fs.joinpath(repo_root, config.options.data_dir)
end

function M.annotations_path(repo_root)
  return vim.fs.joinpath(M.data_dir(repo_root), config.options.annotations_file)
end

function M.prompt_path(repo_root)
  return vim.fs.joinpath(M.data_dir(repo_root), config.options.prompt_file)
end

local function empty_data()
  return { next_id = 1, files = {} }
end

-- Allocates the next annotation id and bumps the counter.
local function next_id(data)
  local id = data.next_id or 1
  data.next_id = id + 1
  return id
end

-- Float seconds, or nil when the file doesn't exist.
local function mtime_of(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end
  return stat.mtime.sec + (stat.mtime.nsec or 0) / 1e9
end

-- Marks the cached table as having unsaved in-memory changes, so `load()`
-- won't re-read the file out from under a batch of pending mutations.
local function mark_dirty(repo_root)
  local entry = cache[repo_root]
  if entry then
    entry.dirty = true
  end
end

-- Empty annotation lists are pruned rather than stored, so `files` never
-- accumulates keys for files whose annotations have all been deleted.
local function set_file_annotations(data, rel_path, list)
  data.files[rel_path] = #list > 0 and list or nil
end

local function read_json(path)
  -- readfile throws error when the file doesn't exist or isn't readable.
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return nil
  end
  local content = table.concat(lines, "\n")
  if vim.trim(content) == "" then
    return nil
  end
  local decoded
  ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    util.notify("could not parse " .. path .. ": " .. tostring(decoded), vim.log.levels.WARN)
    return nil
  end
  return decoded
end

-- `vim.json.encode` emits everything on one line, and annotations.json is meant
-- to be read (and occasionally hand-edited, or written by an agent), so
-- serialise the structure ourselves. Scalars still go through
-- `vim.json.encode` so string escaping stays correct. Keys are sorted to keep
-- diffs between saves minimal.
local function encode_pretty(value, indent)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if next(value) == nil then
    return "{}"
  end

  local pad = indent .. "  "
  local parts = {}
  if vim.islist(value) then
    for _, item in ipairs(value) do
      parts[#parts + 1] = pad .. encode_pretty(item, pad)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = pad .. vim.json.encode(tostring(key)) .. ": " .. encode_pretty(value[key], pad)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function write_json(path, data)
  local ok, encoded = pcall(encode_pretty, data, "")
  if not ok then
    util.notify("could not encode annotation store: " .. tostring(encoded), vim.log.levels.ERROR)
    return false
  end
  local written
  ok, written = pcall(vim.fn.writefile, vim.split(encoded, "\n", { plain = true }), path)
  if not ok or written ~= 0 then
    util.notify("could not write " .. path, vim.log.levels.ERROR)
    return false
  end
  return true
end


-- Makes a decoded store safe to use: annotations.json is hand- and
-- agent-editable, so nothing in it can be trusted to be well-formed.
-- Fills in defaults, keeps the id allocator ahead of every id actually
-- present, and drops files whose annotation lists are empty.
local function normalize(data)
  data.files = type(data.files) == "table" and data.files or {}
  data.next_id = tonumber(data.next_id) or 1

  for rel_path, list in pairs(data.files) do
    if type(list) ~= "table" or #list == 0 then
      data.files[rel_path] = nil
    else
      for _, annotation in ipairs(list) do
        annotation.kind = annotation.kind or "line"
        if not annotation.id then
          annotation.id = next_id(data)
        elseif annotation.id >= data.next_id then
          data.next_id = annotation.id + 1
        end
      end
    end
  end

  return data
end


--- Return the cached table for `repo_root`, reading it from disk first if it
--- has never been read or if the file changed underneath us (another Neovim
--- instance, a `git checkout`, or an agent rewriting annotations.json).
---
--- In-memory mutations win. Once something is `dirty` the file is not re-read
--- until the next `save()`.
function M.load(repo_root)
  local file = M.annotations_path(repo_root)
  local entry = cache[repo_root]
  local mtime = mtime_of(file)
  -- mtime has 1s granularity on some filesystems, so an external write within
  -- the same second as our own can be missed. Good enough for a workflow where
  -- the alternative is re-reading json on every keystroke.
  if entry and (entry.dirty or entry.mtime == mtime) then
    return entry.data
  end

  local raw = read_json(file)
  local data
  if type(raw) == "table" then
    data = normalize(raw)
  end

  cache[repo_root] = { data = data or empty_data(), mtime = mtime }
  return cache[repo_root].data
end

--- Write the cached data table for `repo_root` back to `annotations.json`.
--- A no-op if nothing has been loaded for that root yet.
function M.save(repo_root)
  local entry = cache[repo_root]
  if not entry then
    return
  end

  vim.fn.mkdir(M.data_dir(repo_root), "p")
  local file = M.annotations_path(repo_root)
  if write_json(file, entry.data) then
    entry.dirty = false
    entry.mtime = mtime_of(file)
  end
end


-- Sorts `annotations` by start line **in place**, returning the same table for
-- convenience at call sites that pass a freshly built list.
local function sort_by_line(annotations)
  table.sort(annotations, function(a, b)
    return a.start_line < b.start_line
  end)
  return annotations
end

function M.get_file_annotations(repo_root, rel_path)
  local data = M.load(repo_root)
  return data.files[rel_path] or {}
end

--- Returns the annotation from the cache corresponding to the provided line.
---
--- `line` is a 1-indexed buffer line, matched inclusively against the
--- annotation's start_line/end_line.
function M.find_annotation_at_line(repo_root, rel_path, line)
  for _, annotation in ipairs(M.get_file_annotations(repo_root, rel_path)) do
    if annotation.kind == "line" and line >= annotation.start_line and line <= annotation.end_line then
      return annotation
    end
  end
  return nil
end

--- First annotation overlapping the inclusive line range `start_line..end_line`.
---
--- Used by the range form of reanchoring, where the user selects the code they
--- want an annotation bound to: the selection has to touch the annotation somewhere,
--- but need not match its stored range.
function M.find_annotation_in_range(repo_root, rel_path, start_line, end_line)
  for _, annotation in ipairs(M.get_file_annotations(repo_root, rel_path)) do
    if annotation.kind == "line" and annotation.start_line <= end_line and start_line <= annotation.end_line then
      return annotation
    end
  end
  return nil
end

-- Get annotation by id
local function find_by_id(list, id)
  for _, annotation in ipairs(list) do
    if annotation.id == id then
      return annotation
    end
  end
  return nil
end

--- The annotation identified by `id` in `rel_path`, or nil.
---
--- Position-independent lookup, for callers holding an id across an
--- interaction the buffer may have drifted under (i.e. the cut register).
function M.get_by_id(repo_root, rel_path, id)
  return find_by_id(M.load(repo_root).files[rel_path] or {}, id)
end

function M.all_files(repo_root)
  local names = vim.tbl_keys(M.load(repo_root).files)
  table.sort(names)
  return names
end


--- Overlapping annotations are REPLACED.
---
---@param annotation { start_line: integer, end_line: integer, intent: string, body: string, anchor?: table, id?: integer, orphaned?: boolean }
--- `annotation.id`, if given, forces that id (rather than allocating or
--- inheriting one from a single overlapping annotation) -- used by
--- `restore_deleted` to bring a stashed annotation back with its old identity
--- (and `orphaned` flag, if it had one).
---
---@return table[] replaced annotations that were removed to make room, so the
--- caller can offer an undo for them
function M.upsert_line_annotation(repo_root, rel_path, annotation)
  local data = M.load(repo_root)
  local list = data.files[rel_path] or {}
  local start_line, end_line = annotation.start_line, annotation.end_line
  local kept, removed = {}, {}
  for _, existing in ipairs(list) do
    local overlaps = existing.kind == "line" and existing.start_line <= end_line and start_line <= existing.end_line
    if overlaps then
      table.insert(removed, existing)
    else
      table.insert(kept, existing)
    end
  end

  local body = vim.trim(annotation.body or "")
  if body ~= "" then
    local id
    if annotation.id then
      id = annotation.id
      if annotation.id >= (data.next_id or 1) then
        data.next_id = annotation.id + 1
      end
    elseif #removed == 1 and removed[1].id then
      -- Editing (not replacing) the one annotation this overlaps: keep its identity.
      id = removed[1].id
    else
      id = next_id(data)
    end

    local new_annotation = {
      id = id,
      kind = "line",
      start_line = start_line,
      end_line = end_line,
      intent = annotation.intent,
      body = body,
    }
    if annotation.anchor then
      new_annotation.anchor = annotation.anchor
    end
    if annotation.orphaned then
      new_annotation.orphaned = true
    end
    table.insert(kept, new_annotation)

    -- An annotation that inherited its id is an edit, not a replacement: there's
    -- nothing to undo.
    if #removed == 1 and removed[1].id == id then
      removed = {}
    end
  end

  set_file_annotations(data, rel_path, sort_by_line(kept))
  mark_dirty(repo_root)
  M.save(repo_root)
  return removed
end

--- Removes the annotation identified by `id`.
---
---@return table? removed the annotation that was deleted, if any
function M.delete_by_id(repo_root, rel_path, id)
  local data = M.load(repo_root)
  local list = data.files[rel_path]
  if not list then
    return nil
  end
  for i, annotation in ipairs(list) do
    if annotation.id == id then
      local removed = table.remove(list, i)
      set_file_annotations(data, rel_path, list)
      mark_dirty(repo_root)
      M.save(repo_root)
      return removed
    end
  end
  return nil
end

--- Writes a corrected position (likely coming from `track.sync`) into the
--- store for the annotation identified by `id`.
---
--- Returns whether anything actually changed, so `track.sync` can skip writing
--- to disk when nothing moved.
---
--- Does not save; expects that callers batch multiple updates and save once.
function M.update_position(repo_root, rel_path, id, start_line, end_line)
  local data = M.load(repo_root)
  local list = data.files[rel_path]
  local annotation = list and find_by_id(list, id)
  if not annotation then
    return false
  end
  if annotation.start_line == start_line and annotation.end_line == end_line then
    return false
  end
  annotation.start_line = start_line
  annotation.end_line = end_line
  sort_by_line(list)
  mark_dirty(repo_root)
  return true
end

--- Flags the annotation identified by `id` as orphaned.
---
--- This happens when a tracked range was deleted entirely. We flag without
--- removing it so that it shows up at the last-known position and the user can
--- address
---
--- Returns whether anything changed.
---
--- Does not save; expects callers batch multiple updates and save once.
function M.mark_orphaned(repo_root, rel_path, id)
  local data = M.load(repo_root)
  local annotation = find_by_id(data.files[rel_path] or {}, id)
  if not annotation or annotation.orphaned then
    return false
  end
  annotation.orphaned = true
  mark_dirty(repo_root)
  return true
end

--- Clears the `orphaned` flag on the annotation identified by `id`.
---
--- The counterpart to `mark_orphaned`, for when a deleted range comes back --
--- typically an undo, which un-invalidates the extmark `track.lua` placed.
--- The anchor is left alone. Whether the restored text still
--- matches is up to `anchor.state` ("ok" vs "stale")
---
--- Returns whether anything changed.
---
--- Does not save; expects callers batch multiple updates and save once.
function M.clear_orphaned(repo_root, rel_path, id)
  local data = M.load(repo_root)
  local annotation = find_by_id(data.files[rel_path] or {}, id)
  if not annotation or not annotation.orphaned then
    return false
  end
  annotation.orphaned = nil
  mark_dirty(repo_root)
  return true
end

--- Re-captures `anchor` for `id` and clears its orphaned flag.
---
--- `position` (optional) also *moves* the annotation to `{ start_line, end_line }`
---
--- Unlike `upsert_line_annotation` this does not replace annotations the new
--- range overlaps
---@param position? { start_line: integer, end_line: integer }
function M.reanchor(repo_root, rel_path, id, captured, position)
  local data = M.load(repo_root)
  local list = data.files[rel_path] or {}
  local annotation = find_by_id(list, id)
  if not annotation then
    return false
  end
  if position then
    annotation.start_line = position.start_line
    annotation.end_line = position.end_line
    sort_by_line(list)
  end
  annotation.anchor = captured
  annotation.orphaned = nil
  mark_dirty(repo_root)
  M.save(repo_root)
  return true
end

--- Moves the annotation identified by `id` from `from_rel` to `position` in
--- `to_rel`, re-anchoring it there.
---
--- Keeps the annotation's `id`. Since `next_id` is global for the repo, not
--- per file, ids stay unique across the move, and the extmark ids `track.lua`
--- uses are per-buffer anyway.
---
--- Unlike `upsert_line_annotation` this does **not** evict annotations the
--- destination overlaps. Also unlike an edit, a move always re-captures the
--- anchor and clears `orphaned` -- you just told us where the annotation
--- belongs, so the result is never born `stale`.
---
---@param position { start_line: integer, end_line: integer }
---@param captured table anchor for `position` in the destination file
---@return table? moved the annotation at its new home, or nil if `id` was gone
function M.move_by_id(repo_root, from_rel, id, to_rel, position, captured)
  local data = M.load(repo_root)
  local from_list = data.files[from_rel]
  local annotation = from_list and find_by_id(from_list, id)
  if not annotation then
    return nil
  end

  for i, existing in ipairs(from_list) do
    if existing.id == id then
      table.remove(from_list, i)
      break
    end
  end
  -- Prune the source first, then read the destination back out of `data`: when
  -- from_rel == to_rel that's the same (already shortened) list, so the
  -- annotation is reinserted into it exactly once.
  set_file_annotations(data, from_rel, from_list)

  annotation.start_line = position.start_line
  annotation.end_line = position.end_line
  annotation.anchor = captured
  annotation.orphaned = nil

  local to_list = data.files[to_rel] or {}
  table.insert(to_list, annotation)
  set_file_annotations(data, to_rel, sort_by_line(to_list))

  mark_dirty(repo_root)
  M.save(repo_root)
  return annotation
end

function M.clear_all(repo_root)
  cache[repo_root] = { data = empty_data(), dirty = true }
  M.save(repo_root)
end

return M
