-- `:checkhealth punchlist`
--
-- Check things like nvim version, snacks plugin installed, ability to write to
-- the storage dir.

local M = {}

-- We use nvim 0.11+ features
local function check_nvim()
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11+ required, found " .. tostring(vim.version()))
  end
end


-- Not only is snacks installed, but does it specifically have the bits we need
-- enabled?
local function check_snacks()
  if not pcall(require, "snacks") then
    vim.health.error("snacks.nvim not found", {
      "Add folke/snacks.nvim as a dependency of punchlist.nvim",
    })
    return
  end
  if type(_G.Snacks) ~= "table" then
    vim.health.error("snacks.nvim is installed but not loaded (global `Snacks` is missing)", {
      "Make sure snacks.setup() has run before require('punchlist').setup()",
    })
    return
  end

  vim.health.ok("snacks.nvim loaded")
  for _, mod in ipairs({ "win", "input", "picker", "notify", "toggle", "util" }) do
    if Snacks[mod] == nil then
      vim.health.warn(("Snacks.%s is unavailable; enable it in snacks.setup()"):format(mod))
    end
  end
end


-- Read/write the storage dir. Also warn if it hasn't been gitignored since
-- it's unlikely it should be committed
local function check_store()
  local config = require("punchlist.config")
  local store = require("punchlist.store")
  local util = require("punchlist.util")

  local _, repo_root = util.relative_path(0)
  vim.health.info("repo root: " .. repo_root)

  local dir = store.data_dir(repo_root)
  local stat = vim.uv.fs_stat(dir)
  if not stat then
    vim.health.info(dir .. " does not exist yet (it's created on first save)")
  elseif stat.type ~= "directory" then
    vim.health.error(dir .. " exists but is not a directory")
  elseif vim.uv.fs_access(dir, "W") then
    vim.health.ok(dir .. " is writable")
  else
    vim.health.error(dir .. " is not writable")
  end

  local annotations = store.annotations_path(repo_root)
  local ok, data = pcall(store.load, repo_root)
  if not ok then
    vim.health.error("could not load " .. annotations .. ": " .. tostring(data))
    return
  end
  local files, total = 0, 0
  for _, list in pairs(data.files) do
    files = files + 1
    total = total + #list
  end
  vim.health.ok(("%d annotation(s) across %d file(s)"):format(total, files))

  -- The data dir is deliberately not gitignored by default, but it's almost
  -- never what you want committed.
  if vim.uv.fs_stat(vim.fs.joinpath(repo_root, ".git")) then
    local result = vim.system({ "git", "check-ignore", "-q", config.options.data_dir }, { cwd = repo_root }):wait()
    if result.code == 0 then
      vim.health.ok(config.options.data_dir .. "/ is gitignored")
    else
      vim.health.warn(config.options.data_dir .. "/ is not gitignored", {
        ("echo '%s/' >> %s"):format(config.options.data_dir, vim.fs.joinpath(repo_root, ".gitignore")),
      })
    end
  end
end

function M.check()
  vim.health.start("punchlist")
  check_nvim()
  check_snacks()
  check_store()
end

return M
