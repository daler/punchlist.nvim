local M = {}

M.defaults = {
  -- Directory (relative to the git repo root, or cwd if not in a repo) used
  -- to persist annotations and compiled prompts. It's a dotdir so it stays out
  -- of the way; add it to your project's .gitignore if you don't want it
  -- showing up in `git status`.
  data_dir = ".punchlist",
  annotations_file = "annotations.json",
  prompt_file = "prompt.txt",

  -- Set to false if you want to define your own keymaps around the
  -- functions in lua/punchlist/init.lua instead of the defaults below.
  default_keymaps = true,

  glyphs = {
    fix = "\u{25b6}", -- ▶
    discuss = "\u{25b2}", -- ▲
    continuation = "\u{2502}", -- │
    stale = "!",
    orphaned = "x",
    -- Shown instead of the intent glyph while an annotation is cut and waiting to
    -- be pasted somewhere (see `:PunchlistCut`).
    cut = "\u{2702}", -- ✂
  },

  highlights = {

    -- Colors for glyphs in the gutter
    fix = "DiagnosticInfo",
    discuss = "DiagnosticOK",
    continuation = "Comment",
    stale = "DiagnosticWarn",
    orphaned = "DiagnosticError",
    -- An annotation cut and waiting for a paste target.
    cut = "DiagnosticHint",

    -- Virtual text colors
    virtual_text_fix = "DiagnosticInfo",
    virtual_text_discuss = "DiagnosticOK",

    -- Applied to the lines of a visual selection while its annotation editor is
    -- open, so you can still see what you're annotating on.
    pending_range = "Visual",
  },

  -- Master switch for the line-tracking system. When false, positions are
  -- never corrected and annotations are never flagged stale/orphaned.
  line_tracking = true,

  virtual_text = true,

  -- Prefix shown before the virtual text body
  virtual_text_prefix_fix = "  fix:",
  virtual_text_prefix_discuss = "  discuss:",

  -- Only meaningful for the single-line positions below (the length of the
  -- truncated line, not the body itself).
  virtual_text_max_len = 60,
  -- "below": the whole body on virtual lines underneath the annotated line.
  -- Anything else is passed straight through to the extmark's
  -- `virt_text_pos`, so all of nvim's own placements work:
  --   "eol"             one truncated line after the end of the line
  --   "eol_right_align" same, but flushed to the right edge of the window
  --   "right_align"     flushed right, on top of any text there
  --   "inline"          inserted into the line, shifting the code right
  --   "overlay"         drawn over the top of the code
  virtual_text_pos = "eol",

  -- Annotation editor window (a snacks.win config). Cursor-relative with no
  -- backdrop so the code under review stays readable.
  float = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 0.5,
    height = 6,
    min_width = 40,
    border = "rounded",
    backdrop = false,
    resize = true,
  },

  -- Read-only hover window used by `peek_at_cursor()`.
  peek = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 0.5,
    height = 12,
    min_width = 40,
    border = "rounded",
    backdrop = false,
  },

  -- The following text will be prepended to the prompt, depending on which
  -- intents (fix, discuss) were requested.
  prompt_headers = {
    both = {
      "Process the following review feedback.",
      "",
      "Rules:",
      "- For FIX items: make the requested changes.",
      "- For DISCUSS items: do not edit files, write code, or make repo changes to address them.",
      "- Treat DISCUSS items as non-actionable discussion prompts; answer them only in prose.",
      "",
    },
    fix = {
      "Address the following review feedback by making the requested changes.",
      "",
    },
    discuss = {
      "Respond to the following review discussion items in prose only.",
      "Do not edit files, write code, or make repo changes.",
      "",
    },
  },

  -- Options for viewing all annotations.
  --
  -- "file": the buffer follows the selection. Best for walking through
  --         everything you flagged.
  -- "body": a preview pane showing the full annotation body. Best for when you
  --         want to read what you wrote on each item; Enter will move the buffer
  --         there.
  list_preview = "file",
}

M.options = vim.deepcopy(M.defaults)

M.virtual_text_positions = {
  below = true,
  eol = true,
  eol_right_align = true,
  right_align = true,
  inline = true,
  overlay = true,
}

M.list_previews = { file = true, body = true }

-- Fails loudly on a typo
local function validate(opts)
  local function one_of(set)
    return function(value)
      return set[value] == true
    end
  end

  vim.validate("data_dir", opts.data_dir, "string")
  vim.validate("annotations_file", opts.annotations_file, "string")
  vim.validate("prompt_file", opts.prompt_file, "string")
  vim.validate("default_keymaps", opts.default_keymaps, "boolean")
  vim.validate("line_tracking", opts.line_tracking, "boolean")
  vim.validate("virtual_text", opts.virtual_text, "boolean")
  vim.validate("virtual_text_max_len", opts.virtual_text_max_len, "number")
  vim.validate("glyphs", opts.glyphs, "table")
  vim.validate("highlights", opts.highlights, "table")
  vim.validate("prompt_headers", opts.prompt_headers, "table")
  vim.validate("float", opts.float, "table")
  vim.validate("peek", opts.peek, "table")
  vim.validate(
    "virtual_text_pos",
    opts.virtual_text_pos,
    one_of(M.virtual_text_positions),
    true,
    'one of "' .. table.concat(vim.tbl_keys(M.virtual_text_positions), '", "') .. '"'
  )
  vim.validate(
    "list_preview",
    opts.list_preview,
    one_of(M.list_previews),
    true,
    'one of "file" or "body"'
  )
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate(merged)
  M.options = merged
  return M.options
end

return M
