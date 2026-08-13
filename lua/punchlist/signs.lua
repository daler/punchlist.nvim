local config = require("punchlist.config")
local anchor = require("punchlist.anchor")
local register = require("punchlist.register")
local util = require("punchlist.util")

local M = {}

local ns = vim.api.nvim_create_namespace("punchlist")
-- Separate namespace: the pending-range highlight is transient UI state, not
-- part of the persisted annotation rendering, and gets cleared independently.
local pending_ns = vim.api.nvim_create_namespace("punchlist_pending")

-- Called once from setup(). `managed = true` makes snacks re-apply the links
-- after every `:colorscheme`
function M.setup_highlights()
  local hl = config.options.highlights
  Snacks.util.set_hl({
    FixSign = hl.fix,
    DiscussSign = hl.discuss,
    ContinuationSign = hl.continuation,
    StaleSign = hl.stale,
    OrphanedSign = hl.orphaned,
    CutSign = hl.cut,
    FixVirtualText = hl.virtual_text_fix,
    DiscussVirtualText = hl.virtual_text_discuss,
    StaleVirtualText = hl.stale,
    OrphanedVirtualText = hl.orphaned,
    CutVirtualText = hl.cut,
    PendingRange = hl.pending_range,
  }, { prefix = "Punchlist", default = true, managed = true })
end

-- Gutter glyph + sign/virtual-text highlight groups + virtual-text prefix for
-- an intent, i.e. everything the renderer needs to draw a non-drifted
-- annotation.
local function style_for(intent)
  local glyphs = config.options.glyphs
  if intent == "discuss" then
    return glyphs.discuss, "PunchlistDiscussSign", "PunchlistDiscussVirtualText",
      config.options.virtual_text_prefix_discuss
  end
  return glyphs.fix, "PunchlistFixSign", "PunchlistFixVirtualText", config.options.virtual_text_prefix_fix
end

-- Attaches the inline body to an extmark opts table: either the full body on
-- virtual lines below (which doesn't compete with diagnostics/blame for the end
-- of the line), or one truncated line placed wherever `virtual_text_pos` says.
local function add_virtual_text(opts, body, hl_group, prefix)
  if not config.options.virtual_text then
    return
  end
  if config.options.virtual_text_pos == "below" then
    opts.virt_lines = vim.iter(vim.gsplit(body, "\n", { plain = true }))
      :map(function(line)
        return { { prefix .. line, hl_group } }
      end)
      :totable()
    opts.virt_lines_above = false
  else
    local preview = util.truncate(util.first_line(body), config.options.virtual_text_max_len)
    opts.virt_text = { { prefix .. preview, hl_group } }
    opts.virt_text_pos = config.options.virtual_text_pos
  end
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

-- Paints [start_line, end_line] while an annotation editor is open for that range,
-- so a visual selection stays visible after leaving visual mode.
function M.highlight_pending_range(bufnr, start_line, end_line)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  M.clear_pending_range(bufnr)
  -- `regtype = "V"` makes this linewise, and vim.hl.range clamps to the
  -- buffer for us -- one call instead of an extmark per line.
  vim.hl.range(bufnr, pending_ns, "PunchlistPendingRange", { start_line - 1, 0 }, { end_line - 1, 0 }, {
    regtype = "V",
    inclusive = true,

    -- if this is lower (like 100), that conflicts with default treesitter,
    -- making the highlighting look patchy. This at least needs to be higher
    -- priority than anything else that sets the background color.
    priority = 1000,
  })
end

function M.clear_pending_range(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, pending_ns, 0, -1)
  end
end

-- Redraws every sign/virtual-text marker for `bufnr` from `annotations`
-- (already filtered to that buffer's file). Call this after any add/edit/
-- delete so the gutter always reflects on-disk state.
function M.render(bufnr, annotations)
  M.clear(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  -- Fetched once per file (not per annotation) so drift detection doesn't cost
  -- an extra buffer read per line annotation.
  local buf_lines = config.options.line_tracking and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or nil

  -- Drift state -> presentation. Built per-render (cheap) so it always
  -- reflects live config (e.g. after a `glyphs`/`highlights` change).
  local drift = {
    stale = {
      glyph = config.options.glyphs.stale,
      sign_hl = "PunchlistStaleSign",
      virt_hl = "PunchlistStaleVirtualText",
      prefix = "[stale] ",
    },
    orphaned = {
      glyph = config.options.glyphs.orphaned,
      sign_hl = "PunchlistOrphanedSign",
      virt_hl = "PunchlistOrphanedVirtualText",
      prefix = "[orphaned] ",
    },
  }

  -- Id of the annotation cut and awaiting a paste, if it's in this file. Marked
  -- in the gutter because a pending cut is otherwise invisible state, and
  -- forgetting you have one is the main way a cut/paste register goes wrong.
  local cut_id = register.pending_id(bufnr)

  for _, annotation in ipairs(annotations) do
    local glyph, hl, virt_hl, virt_prefix = style_for(annotation.intent)
    local label = drift[anchor.state(annotation, buf_lines)]
    if label then
      glyph, hl, virt_hl = label.glyph, label.sign_hl, label.virt_hl
      virt_prefix = label.prefix .. virt_prefix
    end
    -- Takes precedence over the drift styling: the cut is the thing you're
    -- mid-way through and about to resolve. The drift prefix is kept, so a
    -- stale annotation that's been cut still says so.
    if annotation.id == cut_id then
      glyph, hl, virt_hl = config.options.glyphs.cut, "PunchlistCutSign", "PunchlistCutVirtualText"
      virt_prefix = "[cut] " .. virt_prefix
    end
    local start_row = math.max(0, annotation.start_line - 1)
    if start_row < line_count then
      local opts = { sign_text = glyph, sign_hl_group = hl, priority = 20 }
      add_virtual_text(opts, annotation.body, virt_hl, virt_prefix)
      vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, opts)
    end

    -- Mark the rest of a multiline range with a dimmer continuation glyph
    -- so the extent of the annotation is visible in the gutter, not just its
    -- first line.
    for line = annotation.start_line + 1, math.min(annotation.end_line, line_count) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
        sign_text = config.options.glyphs.continuation,
        sign_hl_group = "PunchlistContinuationSign",
        priority = 10,
      })
    end
  end
end

return M
