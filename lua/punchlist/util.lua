-- Various utiltiy functions used throughout the plugin.

local M = {}

-- All user-facing messages go through snacks' notifier so repeated saves can
-- replace each other (via `opts.id`)
---@param msg string
---@param level? number
---@param opts? table extra snacks.notify options (e.g. `id`)
function M.notify(msg, level, opts)
  opts = vim.tbl_extend("force", { title = "punchlist", level = level or vim.log.levels.INFO }, opts or {})
  Snacks.notify(msg, opts)
end

--- First line of a (possibly multiline) annotation body. Used for
--- a human-readable indicator of where the annotation was originally attached
function M.first_line(body)
  return vim.gsplit(body, "\n", { plain = true })()
end

--- `s`, truncated to `max` *characters* with a trailing ellipsis if it's
--- longer.
function M.truncate(s, max)
  if vim.fn.strchars(s) > max then
    return vim.fn.strcharpart(s, 0, max - 1) .. "\u{2026}" -- ellipsis character
  end
  return s
end

--- `rel_path:line` or `rel_path:start-end` for a line range.
function M.location_for(rel_path, start_line, end_line)
  if start_line == end_line then
    return string.format("%s:%d", rel_path, start_line)
  end
  return string.format("%s:%d-%d", rel_path, start_line, end_line)
end

--- `rel_path:line` or `rel_path:start-end` for a stored line/range annotation.
function M.location(rel_path, annotation)
  return M.location_for(rel_path, annotation.start_line, annotation.end_line)
end

--- Iterator over every loaded buffer.
---@return Iter
function M.loaded_bufs()
  return vim.iter(vim.api.nvim_list_bufs()):filter(vim.api.nvim_buf_is_loaded)
end

--- The loaded buffer backed by `path`, or nil. Buffer names are unique per
--- file, so at most one can match.
---
--- Note: not using `vim.fn.bufnr(path)` because that falls back to *partial*
--- (regexp) buffer-name matching, which can happily return an unrelated buffer
--- whose name merely contains `path`.
---@param path string absolute path
---@return integer?
function M.buf_for_path(path)
  local target = vim.fs.normalize(path)
  return M.loaded_bufs():find(function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return name ~= "" and vim.fs.normalize(name) == target
  end)
end

--- True for buffers that represent a real file on disk. Filters out help,
--- terminal, quickfix and plugin scratch buffers, which have no business
--- carrying review annotations.
function M.is_file_buf(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

-- Returns (relative_path, repo_root) for a buffer's file, with the path made
-- relative to the repo root so the annotation store stays portable across
-- machines/checkouts.
--
-- `relative_path` is nil when the buffer has no backing file, or when its file
-- lies outside `repo_root` (which matters when a root is passed in: callers
-- use that to ask "is this buffer part of *this* repo?"). `repo_root` is
-- always resolved -- via `vim.fs.root`, which walks up looking for a `.git`
-- entry and so handles submodules and worktrees (where `.git` is a file, not a
-- directory) -- falling back to the file's own directory or, for a fileless
-- buffer, cwd. So callers never need a fallback of their own.
---@param bufnr? integer
---@param repo_root? string
---@return string? rel_path, string repo_root
function M.relative_path(bufnr, repo_root)
  bufnr = bufnr or 0
  if repo_root then
    repo_root = vim.fs.normalize(repo_root)
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    local cwd = vim.fs.normalize(assert(vim.uv.cwd()))
    return nil, repo_root or vim.fs.root(cwd, ".git") or cwd
  end

  -- nvim_buf_get_name is already absolute; normalize only resolves separators
  -- and `~`.
  name = vim.fs.normalize(name)
  -- vim.fs.root takes the head of what it's given, so hand it the file itself.
  -- Normalized because this doubles as the store's cache key and as the base
  -- for relpath below: it has to be byte-identical between calls.
  repo_root = repo_root or vim.fs.normalize(vim.fs.root(name, ".git") or vim.fs.dirname(name))

  -- nil when `name` isn't under `repo_root` at all; "." when they're the same
  -- path, which can't happen for a file under its own ancestor but is cheap to
  -- rule out.
  local rel = vim.fs.relpath(repo_root, name)
  if not rel or rel == "" or rel == "." then
    return nil, repo_root
  end
  return rel, repo_root
end

--- Buffer-specific debouncing (collapsing multiple keypresses during an
--- interval into a single one)
---@param ms integer
---@param fn fun(key: any)
---@return fun(key: any) call, fun(key: any) cancel
function M.debounce(ms, fn)

  local timers = {}

  local function cancel(key)
    local timer = timers[key] -- store copy
    if timer then
      timers[key] = nil -- nuke existing
      timer:stop() -- stop the copy
      if not timer:is_closing() then
        timer:close()
      end
    end
  end

  local function call(key)
    cancel(key) -- throw out an existing timer so the one we create starts from 0
    local timer = vim.uv.new_timer()
    timers[key] = timer
    timer:start(
      ms,
      0,

      -- Timers are created with vim.uv/libuv event loop which is fast. Too
      -- fast for API calls like track.sync() and punchlist.refresh() to
      -- accurately use, so schedule_wrap() runs this on the next safe time to
      -- do so in the slower nvim queue.
      vim.schedule_wrap(function()
        -- A newer `call(key)` may have replaced it during the time between
        -- initially calling this function and now...so make sure it's the same
        -- one we just grabbed above.
        if timers[key] == timer then
          cancel(key)
        end
        fn(key)
      end)
    )
  end

  return call, cancel
end

return M
