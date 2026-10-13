---@mod tuleap tuleap.nvim
---@brief [[
--- Find, list, create, read, update, close and delete Tuleap artifacts
--- (issues, epics, user stories, sprints) from Neovim, with Telescope pickers
--- and burndown / burnup charts rendered straight in the terminal.
---
--- Quick start:
--- >lua
---   require("tuleap").setup({ project = "my-project" })
--- <
--- with `TULEAP_URL` and `TULEAP_TOKEN` exported in your environment.
---@brief ]]

local M = {}

---@type boolean
local initialised = false

--- Configure the plugin.
---@param opts tuleap.Config?
---@return tuleap.Config
function M.setup(opts)
  local config = require("tuleap.config").setup(opts)
  require("tuleap.ui.highlights").setup()
  initialised = true
  return config
end

--- Make sure `setup()` ran, so the plugin also works when it is lazy-loaded by
--- a command or a keymap without an explicit `opts` table.
local function ensure()
  if not initialised then
    M.setup({})
  end
end

---@param fn fun(...)
---@return fun(...)
local function guarded(fn)
  return function(...)
    ensure()
    return fn(...)
  end
end

--------------------------------------------------------------------------- lists

--- Telescope picker over the "issue" tracker.
---@param opts tuleap.PickerOpts?
M.issues = guarded(function(opts)
  require("tuleap.pickers").artifacts(vim.tbl_extend("keep", opts or {}, { kind = "issue" }))
end)

--- Telescope picker over the "epic" tracker.
---@param opts tuleap.PickerOpts?
M.epics = guarded(function(opts)
  require("tuleap.pickers").artifacts(vim.tbl_extend("keep", opts or {}, { kind = "epic" }))
end)

--- Telescope picker over the "story" tracker.
---@param opts tuleap.PickerOpts?
M.stories = guarded(function(opts)
  require("tuleap.pickers").artifacts(vim.tbl_extend("keep", opts or {}, { kind = "story" }))
end)

--- Telescope picker over any tracker key, id or shortname.
---@param kind string
---@param opts tuleap.PickerOpts?
M.list = guarded(function(kind, opts)
  require("tuleap.pickers").artifacts(vim.tbl_extend("keep", opts or {}, { kind = kind }))
end)

--- Artifacts assigned to you.
M.mine = guarded(function()
  require("tuleap.pickers").mine()
end)

--- Prompt for a TQL query and list the matches.
---@param kind string?
M.search = guarded(function(kind)
  require("tuleap.pickers").search(kind)
end)

--- Pick the active project.
M.projects = guarded(function()
  require("tuleap.pickers").projects()
end)

--- Pick a tracker, then browse it.
M.trackers = guarded(function()
  require("tuleap.pickers").trackers()
end)

--- Sprint / milestone picker.
---@param opts table?
M.sprints = guarded(function(opts)
  require("tuleap.pickers").milestones(opts)
end)

--------------------------------------------------------------------------- items

--- Open the detail view of an artifact.
---@param id integer|string|nil defaults to the id under the cursor, then a prompt
M.view = guarded(function(id)
  require("tuleap.actions").view(id)
end)

--- Create an artifact.
---@param kind string? tracker key, defaults to "issue"
M.create = guarded(function(kind)
  require("tuleap.actions").create(kind or "issue")
end)

--- Create an epic.
M.create_epic = guarded(function()
  require("tuleap.actions").create("epic")
end)

--- Create a sprint artifact in the tracker mapped to `trackers.sprint`.
M.create_sprint = guarded(function()
  require("tuleap.actions").create("sprint")
end)

--- Edit an artifact in a form.
---@param id integer|string|nil
M.edit = guarded(function(id)
  require("tuleap.actions").edit(id)
end)

--- Post a follow-up comment.
---@param id integer|string|nil
M.comment = guarded(function(id)
  require("tuleap.actions").comment(id)
end)

--- Move an artifact to a closed status.
---@param id integer|string|nil
M.close = guarded(function(id)
  require("tuleap.actions").close(id)
end)

--- Delete an artifact (site administrators only).
---@param id integer|string|nil
M.delete = guarded(function(id)
  require("tuleap.actions").delete(id)
end)

--- Attach an artifact to an epic or a sprint, asking which.
---@param id integer|string|nil
M.attach = guarded(function(id)
  require("tuleap.actions").attach(id)
end)

--- Attach an artifact under an epic.
---@param id integer|string|nil
M.attach_to_epic = guarded(function(id)
  require("tuleap.actions").attach_to_epic(id)
end)

--- Plan an artifact in a sprint.
---@param id integer|string|nil
M.attach_to_sprint = guarded(function(id)
  require("tuleap.actions").attach_to_sprint(id)
end)

--- Open the artifact in the browser.
---@param id integer|string|nil
M.open_in_browser = guarded(function(id)
  require("tuleap.actions").resolve_artifact(id, function(resolved)
    require("tuleap.actions").open_in_browser(resolved)
  end)
end)

--- Yank the artifact URL.
---@param id integer|string|nil
M.yank_url = guarded(function(id)
  require("tuleap.actions").resolve_artifact(id, function(resolved)
    require("tuleap.actions").yank_url(resolved)
  end)
end)

-------------------------------------------------------------------------- charts

---@param id integer|string|nil
---@param mode "both"|"burndown"|"burnup"
local function sprint_view(id, mode)
  local config = require("tuleap.config")
  local resolved = tonumber(id) or config.state.last_milestone_id
  if resolved then
    return require("tuleap.ui.sprint").open(resolved, { mode = mode })
  end
  -- Nothing to go on: let the user pick a sprint, then honour the mode.
  require("tuleap.pickers").milestones({ title = "Pick a sprint — " .. mode })
end

--- Sprint dashboard: summary, burndown and burnup.
---@param id integer|string|nil
M.sprint = guarded(function(id)
  sprint_view(id, "both")
end)

--- Burndown chart of a sprint.
---@param id integer|string|nil
M.burndown = guarded(function(id)
  sprint_view(id, "burndown")
end)

--- Burnup chart of a sprint.
---@param id integer|string|nil
M.burnup = guarded(function(id)
  sprint_view(id, "burnup")
end)

--------------------------------------------------------------------------- misc

--- Drop the cache and re-read the access key.
M.refresh = guarded(function()
  require("tuleap.actions").refresh()
end)

--- Print the current connection status.
M.status = guarded(function()
  require("tuleap.actions").status()
end)

--- Probe the live instance and report what the plugin found.
M.doctor = guarded(function()
  require("tuleap.doctor").open()
end)

--- `:checkhealth tuleap`
M.health = function()
  require("tuleap.health").check()
end

return M
