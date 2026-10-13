---@mod tuleap.api.projects Projects

local client = require("tuleap.api.client")
local config = require("tuleap.config")

local M = {}

--- List the projects the authenticated user is a member of.
---@param cb fun(err: string?, projects: table[]?)
function M.list(cb)
  client.paginate("/projects", { query = { is_member_of = true } }, function(err, items)
    if err then
      -- Older Tuleap versions reject the `query` filter: retry unfiltered.
      return client.paginate("/projects", nil, cb, { cache_ttl = 600 })
    end
    cb(nil, items)
  end, { cache_ttl = 600 })
end

---@param id integer
---@param cb fun(err: string?, project: table?)
function M.get(id, cb)
  client.get(("/projects/%d"):format(id), nil, cb, { cache_ttl = 600 })
end

--- Resolve the project to work on: the remembered one, the configured one
--- (numeric id or shortname), or nil when the caller must prompt.
---@param cb fun(err: string?, project_id: integer?)
function M.current(cb)
  if config.state.project_id then
    return cb(nil, config.state.project_id)
  end
  local configured = config.options.project
  if type(configured) == "number" then
    config.state.project_id = configured
    return cb(nil, configured)
  end
  if type(configured) == "string" then
    return M.list(function(err, projects)
      if err then
        return cb(err)
      end
      for _, project in ipairs(projects or {}) do
        if project.shortname == configured or project.label == configured then
          config.state.project_id = project.id
          config.state.project_label = project.label
          return cb(nil, project.id)
        end
      end
      cb(("project %q not found among your projects"):format(configured))
    end)
  end
  cb(nil, nil)
end

--- Remember a project for the rest of the session.
---@param project table
function M.select(project)
  config.state.project_id = project.id
  config.state.project_label = project.label or project.shortname
end

return M
