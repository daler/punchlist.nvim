-- Handle the floating windows into which we type annotations

local config = require("punchlist.config")

local M = {}

-- Border color matches corresponding virtual text color
local function border_hl(intent)
  local hl = config.options.highlights
  return intent == "discuss" and hl.virtual_text_discuss or hl.virtual_text_fix
end

-- Ensure the border color sticks even though snacks.nvim may aim to change it.
--
-- Adds `FloatBorder`/`FloatTitle` overrides to `win`'s `winhighlight` without
-- clobbering snacks' own settings, and writes them back into `win.opts.wo` so
-- they survive snacks re-applying `opts.wo` later (e.g. on resize or, for
-- `Snacks.input`, on every keystroke).
local function apply_border_hl(win, group)
  if not win or not win:win_valid() then
    return
  end
  vim.api.nvim_win_call(win.win, function()
    vim.opt_local.winhighlight:append({ FloatBorder = group, FloatTitle = group })
  end)
  win.opts.wo = win.opts.wo or {}
  win.opts.wo.winhighlight = vim.wo[win.win].winhighlight
end

-- Ensure the title also matches the border.
--
-- `Snacks.input`'s title is a list of `{text, hl_group}` chunks with its own
-- hl group baked in, so the `FloatTitle` override above doesn't apply to it.
-- Rewrite those chunks to use `group` instead, via `win:set_title` so it
-- persists across later updates.
local function apply_title_hl(win, group)
  if not win or not win:win_valid() then
    return
  end
  local title = win.opts.title
  if type(title) ~= "table" then
    return
  end
  local retitled = {}
  for _, chunk in ipairs(title) do
    table.insert(retitled, { chunk[1], group })
  end
  win:set_title(retitled, win.opts.title_pos)
end

-- Height of `Snacks.input`: one line of text plus the top/bottom border.
local INPUT_HEIGHT = 3

-- Cursor-relative `row` for a float of `height` (borders included) that must
-- not cover the annotation's own lines. Adjusts if there's no room under the
-- code -- e.g., a multiline editor by default tries to open at the bottom of
-- the selection, but if there's no room then it flips to the top.
--
---@param span? { start_line: integer, end_line: integer }
---@param height integer
---@param prefer "above"|"below"
local function span_row(span, height, prefer)
  local cursor = vim.fn.line(".")
  local above, below = 0, 0
  if span and span.start_line and span.end_line then
    above = cursor - math.min(span.start_line, cursor)
    below = math.max(span.end_line, cursor) - cursor
  end

  local winline = vim.fn.winline()
  local fits_below = vim.fn.winheight(0) - (winline + below) >= height
  local fits_above = (winline - 1) - above >= height

  if prefer == "above" then
    return (fits_above or not fits_below) and -(above + height) or below + 1
  end
  return (fits_below or not fits_above) and below + 1 or -(above + height)
end

-- Snacks accepts a fraction of the editor height as well as an absolute row
-- count; `span_row()` above needs the latter to reason about screen rows.
local function resolved_height(height, fallback)
  height = height or fallback
  if height > 0 and height < 1 then
    return math.floor(vim.o.lines * height)
  end
  return height
end

--- Opens the multiline annotation editor.
---
--- This is a cursor-relative `Snacks.win` scratch buffer pre-filled with
--- `opts.initial_body`.
---
--- Calls `opts.on_submit(body)` when the user confirms (<C-s>).
--- Calls `opts.on_cancel()` when they back out (<Esc>/q/closing the window) without
--- submitting.
--- `body` is the buffer contents joined with "\n".
---
---@param opts { title?: string, footer?: string, filetype?: string, initial_body?: string, start_insert?: boolean, intent?: "fix"|"discuss", span?: { start_line: integer, end_line: integer }, on_submit?: fun(body: string), on_cancel?: fun() }
---@return snacks.win
function M.open_multiline(opts)
  opts = opts or {}

  local committed, body = false, nil
  local win

  local function submit()
    if committed or not win:buf_valid() then
      return
    end
    committed = true
    body = table.concat(win:lines(), "\n")
    win:close()
  end

  local text = {}
  if opts.initial_body and opts.initial_body ~= "" then
    text = vim.split(opts.initial_body, "\n", { plain = true })
  end

  -- uses the "float" key of config options
  local float_cfg = vim.deepcopy(config.options.float)

  -- Only move cursor-relative placements (using helper functions above),
  -- otherwise assume the user knows what they're doing and leave it alone.
  if float_cfg.relative == "cursor" then
    float_cfg.row = span_row(opts.span, resolved_height(float_cfg.height, 6) + 2, "below")
  end

  win = Snacks.win(vim.tbl_deep_extend("force", float_cfg, {
    enter = true,
    ft = opts.filetype or "markdown",
    text = text,
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = "center",
    footer = " " .. (opts.footer or "<C-s> save  \u{b7}  q/<Esc> cancel") .. " ",
    footer_pos = "center",
    wo = { wrap = true },
    keys = {
      punchlist_submit = { "<C-s>", submit, mode = { "n", "i" } },
      q = "close",
      punchlist_cancel = { "<Esc>", "close", mode = "n" },
    },
    on_buf = function(self)
      vim.bo[self.buf].swapfile = false
    end,
    on_win = function(self)
      vim.bo[self.buf].modified = false
      apply_border_hl(self, border_hl(opts.intent))
      if opts.start_insert then
        vim.cmd.startinsert()
      end
    end,
    on_close = function()
      if committed then
        if opts.on_submit then
          -- `committed` is only set (in `submit()`) right after `body` is
          -- assigned, so it's always a string here.
          opts.on_submit(body --[[@as string]])
        end
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end,
  }))

  return win
end

--- One-line prompt at the cursor.
---
--- <C-o> is the only deliberate way to switch to the multiline editor; if a
--- newline otherwise ends up in the prompt (e.g. a paste), it's treated the
--- same way rather than left sitting in a one-line buffer.
---@param opts table same shape as `M.open_multiline`, plus an optional
--- `span = { start_line, end_line }` to keep the prompt clear of a
--- multi-line annotation range
function M.open_oneline_prompt(opts)
  opts = opts or {}
  local escalated = false  -- keep track of  "escalating" to multi-line editing with <C-o>

  -- Hand off to the multiline editor, carrying over whatever's been typed
  -- so far in the one-line window.
  local function escalate(self, typed)
    escalated = true
    self:close()
    vim.schedule(function()
      M.open_multiline(vim.tbl_extend("force", opts, { initial_body = typed, start_insert = true }))
    end)
  end

  local win = Snacks.input({
    prompt = opts.title or "punchlist",
    default = opts.initial_body or "",
    win = {
      relative = "cursor",
      row = span_row(opts.span, INPUT_HEIGHT, "above"),
      col = 0,
      keys = {
        punchlist_expand = {
          "<c-o>",
          function(self)
            -- `self:text()` is the prompt buffer minus its (empty) prompt
            -- prefix
            escalate(self, self:text())
          end,
          mode = { "i", "n" },
        },
      },
      on_buf = function(self)
        -- Handle the corner case where a newline is pasted into the one-line
        -- window, in which case we immediately switch to the multi-line editor
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
          buffer = self.buf,
          callback = function()
            if escalated then
              return
            end
            local typed = self:text()
            if typed:find("\n") then
              escalate(self, typed)
            end
          end,
        })
      end,
    },
  }, function(value)
    if escalated then
      return
    end
    if value == nil then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end
    if opts.on_submit then
      opts.on_submit(value)
    end
  end)
  apply_border_hl(win, border_hl(opts.intent))
  apply_title_hl(win, border_hl(opts.intent))
end

--- One-line input for a single-line body, escalating to the multiline editor
--- (via <C-o>, or automatically) for anything that already has a newline in
--- it.
function M.edit(opts)
  local multiline = (opts.initial_body or ""):find("\n") ~= nil
  if not multiline then
    return M.open_oneline_prompt(opts)
  end
  opts.start_insert = opts.start_insert == nil and (opts.initial_body or "") == "" or opts.start_insert
  return M.open_multiline(opts)
end

--- Read-only hover for an existing annotation body, closing as soon as the cursor
--- moves
---@param opts { title?: string, body: string, span?: { start_line: integer, end_line: integer } }
---@return snacks.win
function M.peek(opts)
  local lines = vim.split(opts.body, "\n", { plain = true })
  local peek_cfg = vim.deepcopy(config.options.peek)
  peek_cfg.height = math.max(1, math.min(resolved_height(peek_cfg.height, 12), #lines))

  -- Like the edit window, we want to avoid hiding the code we've annotated
  peek_cfg.row = span_row(opts.span, peek_cfg.height + 2, "below")

  local win = Snacks.win(vim.tbl_deep_extend("force", peek_cfg, {
    enter = false,  -- keep cursor in the code, not the preview
    ft = "markdown",
    text = lines,
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = "center",
    wo = { wrap = true },
    bo = { modifiable = false },
  }))

  -- Global (not buffer-local) events: the cursor we care about is the one in
  -- the code window, not in the peek buffer. So when we move the cursor in the
  -- code, the window closes.
  win:on({ "CursorMoved", "CursorMovedI", "InsertEnter" }, function()
    win:close()
  end)

  return win
end

--- Read-only confirmation floating window.
---
--- The keymaps are set directly on the scratch buffer rather than through
--- snacks' `keys` spec, and the callbacks fire *after* the window is gone (via
--- `vim.schedule`), so the caller's work happens with focus already back in the
--- code window.
---@param opts { title?: string, lines: string[], footer?: string, intent?: "fix"|"discuss", span?: { start_line: integer, end_line: integer }, on_confirm?: fun(), on_cancel?: fun() }
---@return snacks.win
function M.confirm(opts)
  local settled = false
  local win

  local function finish(confirmed)
    if settled then
      return
    end
    settled = true
    win:close()
    vim.schedule(function()
      local cb = confirmed and opts.on_confirm or opts.on_cancel
      if cb then
        cb()
      end
    end)
  end

  local cfg = vim.deepcopy(config.options.peek)
  cfg.height = math.max(1, #opts.lines)
  cfg.row = span_row(opts.span, cfg.height + 2, "below")

  win = Snacks.win(vim.tbl_deep_extend("force", cfg, {
    enter = true,  -- unlike peek, this window has to receive the <CR> to accept
    ft = "markdown",
    text = opts.lines,
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = "center",
    footer = " " .. (opts.footer or "<CR> confirm  \u{b7}  q/<Esc> cancel") .. " ",
    footer_pos = "center",
    wo = { wrap = true },
    on_buf = function(self)
      -- `nowait` so <CR>/<Esc> resolve immediately instead of waiting to see if
      -- they're the prefix of a longer mapping.
      local function map(lhs, ok)
        vim.keymap.set("n", lhs, function()
          finish(ok)
        end, { buffer = self.buf, nowait = true, silent = true, desc = "punchlist: " .. (ok and "confirm" or "cancel") })
      end
      map("<CR>", true)
      map("q", false)
      map("<Esc>", false)
    end,
    on_win = function(self)
      -- Set here, not via `bo`: snacks fills the buffer from `text` after
      -- applying `bo`, and a non-modifiable buffer can't be filled.
      vim.bo[self.buf].modifiable = false
      -- `enter = true` should already have done this; make it explicit, since
      -- the whole window is useless if it can't receive <CR>.
      if vim.api.nvim_get_current_win() ~= self.win then
        pcall(vim.api.nvim_set_current_win, self.win)
      end
      apply_border_hl(self, border_hl(opts.intent))
    end,
    on_close = function()
      finish(false)
    end,
  }))

  return win
end

return M
