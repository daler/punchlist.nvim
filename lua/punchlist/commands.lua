-- Default keymaps, :Punchlist* commands, virtual-text toggle, and
-- autocmds for tracking.

local config = require("punchlist.config")
local util = require("punchlist.util")

local M = {}

-- Single source of truth for keymaps and commands.
-- `fn` always takes the `punchlist` module as its first argument so this table
-- can be built before `setup()` has a module instance to use
--
---@type { key: string, cmd: string, modes?: string[], range?: boolean, desc: string, fn: fun(punchlist: table, s?: integer, e?: integer) }[]
local actions = {
  {
    key = "pf",
    cmd = "PunchlistFix",
    modes = { "n", "x" },
    range = true,
    desc = "add/edit FIX annotation on this line/selection",
    fn = function(p, s, e)
      p.annotate("fix", s, e)
    end,
  },
  {
    key = "pd",
    cmd = "PunchlistDiscuss",
    modes = { "n", "x" },
    range = true,
    desc = "add/edit DISCUSS annotation on this line/selection",
    fn = function(p, s, e)
      p.annotate("discuss", s, e)
    end,
  },
  {
    key = "pp",
    cmd = "PunchlistPeek",
    desc = "peek at the annotation on this line",
    fn = function(p)
      p.peek_at_cursor()
    end,
  },
  {
    key = "pX",
    cmd = "PunchlistDelete",
    desc = "delete annotation on this line",
    fn = function(p)
      p.delete_at_cursor()
    end,
  },
  {
    key = "pu",
    cmd = "PunchlistUndo",
    desc = "restore the last deleted annotation",
    fn = function(p)
      p.restore_deleted()
    end,
  },
  {
    key = "px",
    cmd = "PunchlistCut",
    desc = "cut the annotation on this line, to paste elsewhere",
    fn = function(p)
      p.cut_at_cursor()
    end,
  },
  {
    key = "pv",
    cmd = "PunchlistPaste",
    modes = { "n", "x" },
    range = true,
    desc = "paste the cut annotation onto this line/selection",
    fn = function(p, s, e)
      p.paste_at_cursor(s, e)
    end,
  },
  {
    key = "pr",
    cmd = "PunchlistReanchor",
    modes = { "n", "x" },
    range = true,
    desc = "reanchor the stale/orphaned annotation on this line (or onto this selection)",
    fn = function(p, s, e)
      p.reanchor_at_cursor(s, e)
    end,
  },
  {
    key = "p]",
    cmd = "PunchlistNext",
    desc = "jump to next annotation",
    fn = function(p)
      p.jump(1)
    end,
  },
  {
    key = "p[",
    cmd = "PunchlistPrev",
    desc = "jump to previous annotation",
    fn = function(p)
      p.jump(-1)
    end,
  },
  {
    key = "pV",
    cmd = "PunchlistList",
    desc = "list all annotations",
    fn = function(p)
      p.list()
    end,
  },
  {
    key = "ps",
    cmd = "PunchlistPrompt",
    desc = "compile & save review prompt",
    fn = function(p)
      p.compile_prompt()
    end,
  },
  {
    key = "pc",
    cmd = "PunchlistClear",
    desc = "clear all annotations in this repo",
    fn = function(p)
      p.clear_all()
    end,
  },
}

local function set_default_keymaps(punchlist)
  for _, action in ipairs(actions) do
    vim.keymap.set(action.modes or "n", "<localleader>" .. action.key, function()
      action.fn(punchlist)
    end, { desc = "punchlist: " .. action.desc, silent = true })
  end
end

local function create_commands(punchlist)
  local cmd = vim.api.nvim_create_user_command
  for _, action in ipairs(actions) do
    cmd(action.cmd, function(opts)
      local s, e
      if action.range and opts.range and opts.range > 0 then
        s, e = opts.line1, opts.line2
      end
      action.fn(punchlist, s, e)
    end, { range = action.range or false, desc = "Punchlist: " .. action.desc })
  end
end

--- Toggle for the inline annotation text, for when it gets noisy mid-review.
---
--- `which_key = false` on purpose to avoid issues with which-key version
--- dependencies.
local function virtual_text_toggle(punchlist)
  return Snacks.toggle({
    id = "punchlist_virtual_text",
    name = "Punchlist Virtual Text",
    which_key = false,
    get = function()
      return config.options.virtual_text
    end,
    set = function(state)
      config.options.virtual_text = state
      punchlist.refresh_all()
    end,
  })
end

local function create_autocmds(punchlist)
  local track = require("punchlist.track")
  local group = vim.api.nvim_create_augroup("Punchlist", { clear = true })

  -- Drift detection re-hashes every annotation in the file, so it's too expensive
  -- to run per keystroke. Debounced instead, which is what makes stale/orphaned
  -- glyphs appear while you type rather than only after some other event
  -- happens to trigger a refresh.
  local refresh_soon, cancel_refresh = util.debounce(250, function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    track.sync(bufnr)
    punchlist.refresh(bufnr)
  end)

  local function on_file_buf(events, callback)
    vim.api.nvim_create_autocmd(events, {
      group = group,
      callback = function(args)
        -- Skip help/terminal/quickfix/scratch buffers: they can't own annotations,
        -- and attaching tracking to them just burns cycles.
        if util.is_file_buf(args.buf) then
          callback(args)
        end
      end,
    })
  end

  on_file_buf({ "BufReadPost", "BufNewFile", "BufWinEnter" }, function(args)
    -- `ensure_attached`, not `resync`: BufWinEnter fires on things like `:split` with no
    -- preceding BufLeave to sync, and rebuilding marks from the store there
    -- would discard any drift accumulated since the last sync.
    track.ensure_attached(args.buf)
    punchlist.refresh(args.buf)
  end)

  on_file_buf({ "TextChanged", "TextChangedI" }, function(args)
    refresh_soon(args.buf)
  end)

  on_file_buf({ "BufWritePost", "InsertLeave", "BufLeave" }, function(args)
    track.sync(args.buf)
  end)

  -- VimLeavePre fires once, right before Neovim exits (but before any
  -- buffers/windows are torn down), so it's the last chance to flush
  -- pending extmark positions to the store.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      track.sync_all()
    end,
  })

  -- FileChangedShellPost fires after Neovim has auto-reloaded a buffer
  -- (e.g. `:checktime` or shell command) whose underlying file changed on
  -- disk while it was open.
  on_file_buf("FileChangedShellPost", function(args)
    -- The content was replaced wholesale, so the old marks describe text that
    -- no longer exists: discard them rather than syncing garbage back into the
    -- store. The anchors will flag whatever drifted.
    track.rebuild(args.buf)
    punchlist.refresh(args.buf)
  end)

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    group = group,
    callback = function(args)
      cancel_refresh(args.buf)
      track.sync(args.buf)
      track.detach(args.buf)
    end,
  })
end

--- Wires up the `:Punchlist*` commands, default keymaps, the virtual-text
--- toggle, and the tracking autocmds against `punchlist` (the module
--- returned by `require("punchlist")`). Called once from `punchlist.setup()`.
function M.setup(punchlist)
  create_commands(punchlist)
  -- Registered unconditionally so `default_keymaps = false` users can still
  -- reach it (via snacks' toggle list, or `:map()` it themselves).
  local toggle = virtual_text_toggle(punchlist)
  if config.options.default_keymaps then
    set_default_keymaps(punchlist)
    toggle:map("<localleader>pt", { desc = "punchlist: toggle the inline annotation text" })
  end
  create_autocmds(punchlist)
end

return M
