-- Given all the annotations so far, builds a prompt that can be optionally
-- edited before copying.

local store = require("punchlist.store")
local anchor = require("punchlist.anchor")
local util = require("punchlist.util")
local config = require("punchlist.config")

local M = {}

-- Appends a note an agent can act on when the line numbers in the prompt
-- might be wrong (stale or orphaned annotations)
--
-- Re-anchoring clears this.
local function with_drift_note(body, annotation, state)
  if state == "stale" then
    local original = annotation.anchor and annotation.anchor.text
    if original then
      return body
        .. string.format(
          '\n(NOTE: the code at this location changed after this annotation was written; the original line was: "%s")',
          original
        )
    end
    return body .. "\n(NOTE: the code at this location changed after this annotation was written)"
  elseif state == "orphaned" then
    return body .. "\n(NOTE: the annotated lines were deleted)"
  end
  return body
end

-- Every annotation for `intent`, returned as `{ location, body }` pairs ready to
-- render into the prompt
local function items_for(repo_root, intent)
  local items = {}
  local lines_for = anchor.lines_reader(repo_root)
  for _, rel_path in ipairs(store.all_files(repo_root)) do
    for _, annotation in ipairs(store.get_file_annotations(repo_root, rel_path)) do
      if annotation.intent == intent then
        local state = anchor.state(annotation, lines_for(rel_path))
        table.insert(items, {
          location = util.location(rel_path, annotation),
          body = with_drift_note(annotation.body, annotation, state),
        })
      end
    end
  end
  return items
end

-- "FIX:" / "DISCUSS:" header followed by numbered, indented item bodies.
local function render(title, items)
  local lines = { title .. ":" }
  for i, item in ipairs(items) do
    table.insert(lines, string.format("%d. %s", i, item.location))
    for body_line in vim.gsplit(item.body, "\n", { plain = true }) do
      table.insert(lines, "   " .. body_line)
    end
    if i < #items then
      table.insert(lines, "")
    end
  end
  return lines
end

-- Composes a prompt from every stored annotation for `repo_root`, grouped into
-- FIX / DISCUSS sections.
function M.compose(repo_root)
  local fix = items_for(repo_root, "fix")
  local discuss = items_for(repo_root, "discuss")
  if #fix == 0 and #discuss == 0 then
    return ""
  end

  local which = (#fix > 0 and #discuss > 0) and "both" or (#fix > 0 and "fix" or "discuss")
  local lines = vim.list_extend({}, config.options.prompt_headers[which])

  if #fix > 0 then
    vim.list_extend(lines, render("FIX", fix))
    if #discuss > 0 then
      table.insert(lines, "")
    end
  end
  if #discuss > 0 then
    vim.list_extend(lines, render("DISCUSS", discuss))
  end

  while lines[#lines] == "" do
    table.remove(lines)
  end

  return table.concat(lines, "\n")
end

return M
