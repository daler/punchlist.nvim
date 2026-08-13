-- Adds a picker where you can see all added annotations at a glance, bounce
-- between them in the buffer, delete them if needed.

local config = require("punchlist.config")
local store = require("punchlist.store")
local anchor = require("punchlist.anchor")
local track = require("punchlist.track")
local util = require("punchlist.util")

local M = {}

-- Built fresh on every call to `picker:find({ refresh = true })`. This allows
-- us to delete inside the picker.
---@param repo_root string
---@param opts { buf?: boolean, rel_path?: string, item_preview: boolean }
local function build_items(repo_root, opts)
  local items = {}
  local lines_for = anchor.lines_reader(repo_root)

  for _, rel_path in ipairs(store.all_files(repo_root)) do
    if not (opts.buf and rel_path ~= opts.rel_path) then
      local abs_path = vim.fs.joinpath(repo_root, rel_path)
      -- Give the picker the existing buffer so that it keeps all the extmarks
      -- and glyphs and everything else from the actual buffer.
      local existing_buf = util.buf_for_path(abs_path)
      for _, annotation in ipairs(store.get_file_annotations(repo_root, rel_path)) do
        local loc = util.location(rel_path, annotation)
        local state = anchor.state(annotation, lines_for(rel_path))
        local tag = state ~= "ok" and (state:upper() .. " ") or ""
        local item = {
          text = string.format("%s%s %s %s", tag, annotation.intent:upper(), loc, util.first_line(annotation.body)),
          file = abs_path,
          buf = existing_buf,
          pos = { annotation.start_line, 0 },
          rel_path = rel_path,
          annotation = annotation,
          location = loc,
          state = state,
        }
        if opts.item_preview then
          item.preview = { text = annotation.body, ft = "markdown" }
        end
        table.insert(items, item)
      end
    end
  end
  return items
end

-- Adds highlighting based on intent (fix/discuss) in the picker
---@param item snacks.picker.Item
---@return snacks.picker.Highlight[]
local function format_item(item)
  local annotation = item.annotation
  local hl = annotation.intent == "discuss" and "PunchlistDiscussSign" or "PunchlistFixSign"
  local parts = {}
  if item.state == "stale" then
    table.insert(parts, { "[STALE] ", "PunchlistStaleSign" })
  elseif item.state == "orphaned" then
    table.insert(parts, { "[ORPHANED] ", "PunchlistOrphanedSign" })
  end
  table.insert(parts, { string.format("%-8s", annotation.intent:upper()), hl })
  table.insert(parts, { item.location .. "  ", "SnacksPickerFile" })
  table.insert(parts, { util.first_line(annotation.body) })
  return parts
end

-- Shared by both the input and the list windows: <a-b> scopes to the current
-- file, <c-x> deletes the selection (or the row under the cursor).
local picker_keys = {
  ["<a-b>"] = { "toggle_buf", mode = { "i", "n" }, desc = "Scope to current file" },
  ["<c-x>"] = { "punchlist_delete", mode = { "i", "n" }, desc = "Delete annotation(s)" },
}

-- presets for the style/layout of the picker
local LIST_LAYOUT = {
  -- "main": the real editor window follows the selection, like
  -- `Snacks.picker.lines`.
  file = { layout = { preview = "main", preset = "ivy" }, preview = nil, item_preview = false },
  -- "body": a dedicated preview pane with the full annotation text.
  body = { layout = { preset = "ivy" }, preview = "preview", item_preview = true },
}

local function list_layout()
  return LIST_LAYOUT[config.options.list_preview]
end

--- Picker over every annotation in the repo.
---
--- <CR> jumps to line with annotation
--- <C-x> deletes the selection (or the row under the cursor) in place
--- <a-b> scopes the list to the current file.
function M.list()
  local bufnr = vim.api.nvim_get_current_buf()
  local rel_path, repo_root = util.relative_path(bufnr)

  local scope_buf = false
  local layout = list_layout()
  local function items()
    return build_items(repo_root, { buf = scope_buf, rel_path = rel_path, item_preview = layout.item_preview })
  end

  local initial = items()
  if #initial == 0 then
    util.notify("no annotations recorded yet")
    return
  end

  return Snacks.picker.pick({
    source = "punchlist",
    title = string.format("Punchlist Annotations (%d)", #initial),
    finder = items,
    format = format_item,
    layout = layout.layout,
    preview = layout.preview,
    main = { current = true },
    confirm = "jump",
    buf = false, -- scope state, flipped by the toggle below
    toggles = { buf = "b" },
    actions = {
      toggle_buf = function(picker)
        scope_buf = not scope_buf
        picker.opts.buf = scope_buf
        picker:find({ refresh = true })
      end,
      punchlist_delete = function(picker)
        local punchlist = require("punchlist")
        ---@type punchlist.Deleted[]
        local deleted = {}
        for _, item in ipairs(picker:selected({ fallback = true })) do
          -- By id: the item's start_line is a snapshot from when the picker
          -- was populated, and the buffer may have moved underneath it since.
          local removed = store.delete_by_id(repo_root, item.rel_path, item.annotation.id)
          if removed then
            table.insert(deleted, { repo_root = repo_root, rel_path = item.rel_path, annotation = removed })
            track.resync_path(repo_root, item.rel_path)
          end
        end
        -- One undo group for the whole multi-select, so restoring brings back
        -- everything the keypress destroyed.
        punchlist.stash_deleted(deleted)
        punchlist.refresh_all()
        picker:find({ refresh = true })
        if #deleted > 0 then
          util.notify(
            #deleted == 1 and "annotation deleted (restore with :PunchlistUndo)"
              or (#deleted .. " annotations deleted (restore with :PunchlistUndo)"),
            nil,
            { id = "punchlist_delete" }
          )
        end
      end,
    },
    win = {
      input = { keys = picker_keys },
      list = { keys = picker_keys },
    },
  })
end

return M
