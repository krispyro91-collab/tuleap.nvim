---@mod tuleap.pickers Telescope pickers
---
--- Data is fetched first and handed to a static finder: Tuleap collections are
--- paginated and slow enough that a live finder would fire a request per
--- keystroke. Fuzzy matching then happens locally, and `expert_query` (TQL) is
--- available when the result set has to be narrowed server side.

local artifacts = require("tuleap.api.artifacts")
local config = require("tuleap.config")
local date = require("tuleap.util.date")
local log = require("tuleap.util.log")
local milestones = require("tuleap.api.milestones")
local projects = require("tuleap.api.projects")
local render = require("tuleap.ui.render")
local trackers = require("tuleap.api.trackers")
local users = require("tuleap.api.users")

local M = {}

---@return table? telescope modules
local function telescope()
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    log.error("telescope.nvim is required for Tuleap pickers")
    return nil
  end
  return {
    pickers = pickers,
    finders = require("telescope.finders"),
    actions = require("telescope.actions"),
    state = require("telescope.actions.state"),
    conf = require("telescope.config").values,
    previewers = require("telescope.previewers"),
    entry_display = require("telescope.pickers.entry_display"),
    utils = require("telescope.utils"),
  }
end

---@param opts table?
---@return table
local function picker_opts(opts)
  return vim.tbl_deep_extend("force", config.options.picker.opts or {}, opts or {})
end

--------------------------------------------------------------------- previewing

--- Build the preview body of an artifact from the data the list already holds.
---@param artifact table
---@param width integer
---@return tuleap.Builder
function M.artifact_preview(artifact, width)
  local builder = render.builder(width)
  local open = artifacts.is_open(artifact)

  builder:line({
    { "  " .. artifacts.xref(artifact) .. "  ", "TuleapXref" },
    { artifacts.title(artifact), "TuleapTitle" },
  })
  builder:rule("─", width)
  builder:field("Status", artifacts.status(artifact), {
    hl = open and "TuleapOpen" or "TuleapClosed",
  })
  builder:field(
    "Submitted",
    ("%s · %s"):format(
      users.label(artifact.submitted_by_user or artifact.submitted_by),
      date.pretty(artifact.submitted_on)
    )
  )
  builder:field("Updated", date.relative(artifact.last_modified_date))

  local description
  for _, value in ipairs(artifact.values or {}) do
    if value.type == "text" and not description then
      description = render.strip_html(trackers.render_value(value))
    end
  end
  if description and description ~= "" then
    builder:section("Description")
    builder:wrap(description, { width = width })
  end

  local shown = false
  for _, value in ipairs(artifact.values or {}) do
    local rendered = value.type ~= "text" and trackers.render_value(value) or ""
    if rendered ~= "" and value.label then
      if not shown then
        builder:section("Fields")
        shown = true
      end
      builder:field(value.label, rendered, { width = 18 })
    end
  end

  return builder
end

---@param ts table telescope modules
---@return table previewer
local function artifact_previewer(ts)
  return ts.previewers.new_buffer_previewer({
    title = "Artifact",
    define_preview = function(self, entry, status)
      local width = vim.api.nvim_win_get_width(self.state.winid or 0) - 2
      local builder = M.artifact_preview(entry.value, width)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, builder.lines)
      local ns = require("tuleap.ui.window").ns
      vim.api.nvim_buf_clear_namespace(self.state.bufnr, ns, 0, -1)
      for _, item in ipairs(builder.highlights) do
        pcall(vim.api.nvim_buf_set_extmark, self.state.bufnr, ns, item.row, item.col, {
          end_col = item.end_col,
          hl_group = item.hl,
        })
      end
    end,
  })
end

------------------------------------------------------------------- entry makers

---@param ts table
---@param list table[]
---@return fun(artifact: table): table
local function artifact_entry_maker(ts, list)
  local icons = config.options.ui.icons
  local id_width = 4
  local status_width = 6
  for _, artifact in ipairs(list) do
    id_width = math.max(id_width, #artifacts.xref(artifact))
    status_width = math.max(status_width, vim.fn.strdisplaywidth(artifacts.status(artifact)))
  end
  id_width = math.min(id_width, 18)
  status_width = math.min(status_width, 16)

  local items = { { width = 2 } }
  if config.options.picker.show_id then
    items[#items + 1] = { width = id_width }
  end
  items[#items + 1] = { width = status_width }
  items[#items + 1] = { remaining = true }

  local displayer = ts.entry_display.create({ separator = " ", items = items })

  return function(artifact)
    local open = artifacts.is_open(artifact)
    local title = artifacts.title(artifact)
    local xref = artifacts.xref(artifact)
    local status = artifacts.status(artifact)
    return {
      value = artifact,
      ordinal = ("%s %s %s"):format(xref, status, title),
      display = function()
        local columns = { { open and icons.open or icons.closed, open and "TuleapOpen" or "TuleapClosed" } }
        if config.options.picker.show_id then
          columns[#columns + 1] = { xref, "TuleapXref" }
        end
        columns[#columns + 1] = { status, open and "TuleapOpen" or "TuleapClosed" }
        columns[#columns + 1] = { title, "TuleapValue" }
        return displayer(columns)
      end,
    }
  end
end

--------------------------------------------------------------------- the pickers

--- Attach the shared artifact mappings to a picker.
---@param ts table
---@param reload fun()?
---@return fun(prompt_bufnr: integer, map: function): boolean
local function artifact_mappings(ts, reload)
  return function(prompt_bufnr, map)
    local actions = require("tuleap.actions")

    ---@param fn fun(id: integer)
    ---@param keep_open boolean?
    local function with_selection(fn, keep_open)
      return function()
        local entry = ts.state.get_selected_entry()
        if not entry then
          return
        end
        if not keep_open then
          ts.actions.close(prompt_bufnr)
        end
        fn(entry.value.id, entry.value)
      end
    end

    ts.actions.select_default:replace(with_selection(function(id)
      require("tuleap.ui.detail").open(id)
    end))

    map({ "i", "n" }, "<C-e>", with_selection(function(id)
      actions.edit(id)
    end))
    map({ "i", "n" }, "<C-x>", with_selection(function(id)
      actions.close(id, { on_done = reload })
    end))
    map({ "i", "n" }, "<C-a>", with_selection(function(id)
      actions.comment(id)
    end))
    map({ "i", "n" }, "<C-o>", with_selection(function(_, artifact)
      actions.open_in_browser(artifact)
    end, true))
    map({ "i", "n" }, "<C-y>", with_selection(function(_, artifact)
      actions.yank_url(artifact)
    end, true))
    map({ "i", "n" }, "<M-d>", with_selection(function(id)
      actions.delete(id, { on_done = reload })
    end))
    return true
  end
end

---@class tuleap.PickerOpts
---@field kind string? tracker key, id or shortname
---@field tracker_id integer?
---@field title string?
---@field expert_query string?
---@field open_only boolean?
---@field artifacts table[]? pre-fetched artifacts, skips the request

--- Generic artifact picker.
---@param opts tuleap.PickerOpts?
function M.artifacts(opts)
  opts = opts or {}
  local ts = telescope()
  if not ts then
    return
  end

  local function show(list, title)
    list = list or {}
    if opts.open_only then
      list = vim.tbl_filter(artifacts.is_open, list)
    end
    if #list == 0 then
      return log.warn("No artifact found%s", opts.expert_query and (" for " .. opts.expert_query) or "")
    end
    table.sort(list, function(a, b)
      return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
    end)

    ts.pickers
      .new(
        picker_opts(),
        vim.tbl_extend("force", {
          prompt_title = title or opts.title or "Tuleap artifacts",
          finder = ts.finders.new_table({
            results = list,
            entry_maker = artifact_entry_maker(ts, list),
          }),
          sorter = ts.conf.generic_sorter({}),
          attach_mappings = artifact_mappings(ts, function()
            vim.schedule(function()
              M.artifacts(opts)
            end)
          end),
        }, config.options.picker.preview and { previewer = artifact_previewer(ts) } or {})
      )
      :find()
  end

  if opts.artifacts then
    return show(opts.artifacts, opts.title)
  end

  local function fetch(tracker_id, title)
    log.debug("Fetching artifacts of tracker %d …", tracker_id)
    artifacts.list(
      tracker_id,
      { expert_query = opts.expert_query },
      function(err, list)
        if err then
          return log.error(err)
        end
        show(list, title)
      end
    )
  end

  if opts.tracker_id then
    return fetch(opts.tracker_id, opts.title)
  end

  trackers.resolve(opts.kind or "issue", function(err, tracker_id)
    if err then
      return log.error(err)
    end
    trackers.get(tracker_id, function(_, tracker)
      fetch(tracker_id, opts.title or (tracker and tracker.label) or "Tuleap artifacts")
    end)
  end)
end

--- Prompt for a TQL expert query, then list the matches.
---@param kind string?
function M.search(kind)
  vim.ui.input({
    prompt = "Tuleap query (TQL, empty = all): ",
    default = config.state.last_query or "",
  }, function(query)
    if query == nil then
      return
    end
    config.state.last_query = query
    M.artifacts({
      kind = kind or "issue",
      expert_query = vim.trim(query),
      title = query ~= "" and ("Tuleap · " .. query) or "Tuleap artifacts",
    })
  end)
end

--- Artifacts assigned to the authenticated user across every configured tracker.
function M.mine()
  local ts = telescope()
  if not ts then
    return
  end
  users.self(function(uerr, me)
    if uerr then
      return log.error(uerr)
    end
    local keys = {}
    for key in pairs(config.options.trackers) do
      keys[#keys + 1] = key
    end
    table.sort(keys)

    local collected, pending = {}, #keys
    if pending == 0 then
      return log.warn("No tracker configured")
    end

    local function done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if #collected == 0 then
        return log.warn("Nothing assigned to %s", users.label(me))
      end
      M.artifacts({ artifacts = collected, title = ("Assigned to %s"):format(users.label(me)) })
    end

    --- Keep only the artifacts whose contributor semantic contains the user.
    ---@param list table[]
    local function keep_mine(list)
      for _, artifact in ipairs(list or {}) do
        for _, value in ipairs(artifact.values or {}) do
          for _, item in ipairs(value.values or {}) do
            if type(item) == "table" and item.id and tostring(item.id) == tostring(me.id) then
              collected[#collected + 1] = artifact
            end
          end
        end
      end
    end

    for _, key in ipairs(keys) do
      trackers.resolve(key, function(err, tracker_id)
        if err then
          return done()
        end
        -- The TQL field name differs between instances, so fall back to a
        -- client side filter when the server rejects the query.
        artifacts.list(tracker_id, { expert_query = "assigned_to = MYSELF()" }, function(qerr, list)
          if qerr then
            return artifacts.list(tracker_id, {}, function(_, all)
              keep_mine(all)
              done()
            end)
          end
          vim.list_extend(collected, list or {})
          done()
        end)
      end)
    end
  end)
end

--- Pick the project every other command works against.
---@param cb fun(project: table)?
function M.projects(cb)
  local ts = telescope()
  if not ts then
    return
  end
  projects.list(function(err, list)
    if err then
      return log.error(err)
    end
    if not list or #list == 0 then
      return log.warn("No project visible with this access key")
    end
    ts.pickers
      .new(picker_opts(), {
        prompt_title = "Tuleap projects",
        finder = ts.finders.new_table({
          results = list,
          entry_maker = function(project)
            return {
              value = project,
              ordinal = ("%s %s"):format(project.shortname or "", project.label or ""),
              display = ("%-28s %s"):format(project.shortname or "", project.label or ""),
            }
          end,
        }),
        sorter = ts.conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          ts.actions.select_default:replace(function()
            local entry = ts.state.get_selected_entry()
            ts.actions.close(prompt_bufnr)
            if not entry then
              return
            end
            projects.select(entry.value)
            log.info("Tuleap project: %s", entry.value.label or entry.value.shortname)
            if cb then
              cb(entry.value)
            end
          end)
          return true
        end,
      })
      :find()
  end)
end

--- Pick a tracker of the current project, then list its artifacts.
function M.trackers()
  local ts = telescope()
  if not ts then
    return
  end
  projects.current(function(err, project_id)
    if err then
      return log.error(err)
    end
    if not project_id then
      return M.projects(function()
        M.trackers()
      end)
    end
    trackers.list(project_id, function(lerr, list)
      if lerr then
        return log.error(lerr)
      end
      if not list or #list == 0 then
        return log.warn("No tracker in this project")
      end
      ts.pickers
        .new(picker_opts(), {
          prompt_title = "Tuleap trackers",
          finder = ts.finders.new_table({
            results = list,
            entry_maker = function(tracker)
              return {
                value = tracker,
                ordinal = ("%s %s"):format(tracker.item_name or "", tracker.label or ""),
                display = ("%-16s %s"):format(tracker.item_name or "", tracker.label or ""),
              }
            end,
          }),
          sorter = ts.conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            ts.actions.select_default:replace(function()
              local entry = ts.state.get_selected_entry()
              ts.actions.close(prompt_bufnr)
              if entry then
                M.artifacts({ tracker_id = entry.value.id, title = entry.value.label })
              end
            end)
            return true
          end,
        })
        :find()
    end)
  end)
end

--- Sprint / milestone picker.
---@param opts {project_id: integer?, parent_id: integer?, title: string?}?
function M.milestones(opts)
  opts = opts or {}
  local ts = telescope()
  if not ts then
    return
  end

  local function show(list, title)
    if not list or #list == 0 then
      return log.warn("No milestone found — is the Agile Dashboard enabled on this project?")
    end
    ts.pickers
      .new(picker_opts(), {
        prompt_title = title or "Tuleap sprints",
        finder = ts.finders.new_table({
          results = list,
          entry_maker = function(milestone)
            local start, finish = date.parse(milestone.start_date), date.parse(milestone.end_date)
            local period = (start and finish)
                and ("%s → %s"):format(date.format(start, "%d/%m"), date.format(finish, "%d/%m"))
              or ""
            return {
              value = milestone,
              ordinal = ("%s %s"):format(milestone.label or "", milestone.semantic_status or ""),
              display = ("%-44s %-10s %s"):format(
                milestones.label(milestone),
                milestone.semantic_status or "",
                period
              ),
            }
          end,
        }),
        sorter = ts.conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          local function with_selection(fn, keep_open)
            return function()
              local entry = ts.state.get_selected_entry()
              if not entry then
                return
              end
              if not keep_open then
                ts.actions.close(prompt_bufnr)
              end
              fn(entry.value)
            end
          end

          ts.actions.select_default:replace(with_selection(function(milestone)
            require("tuleap.ui.sprint").open(milestone.id)
          end))
          map({ "i", "n" }, "<C-b>", with_selection(function(milestone)
            require("tuleap.ui.sprint").chart(milestone.id, "burndown")
          end))
          map({ "i", "n" }, "<C-u>", with_selection(function(milestone)
            require("tuleap.ui.sprint").chart(milestone.id, "burnup")
          end))
          map({ "i", "n" }, "<C-l>", with_selection(function(milestone)
            M.milestones({ parent_id = milestone.id, title = "Sprints of " .. (milestone.label or "") })
          end))
          map({ "i", "n" }, "<C-a>", with_selection(function(milestone)
            M.milestone_content(milestone.id)
          end))
          map({ "i", "n" }, "<C-o>", with_selection(function(milestone)
            require("tuleap.actions").open_url(milestones.url(milestone))
          end, true))
          return true
        end,
      })
      :find()
  end

  if opts.parent_id then
    return milestones.children(opts.parent_id, function(err, list)
      if err then
        return log.error(err)
      end
      show(list, opts.title)
    end)
  end

  projects.current(function(err, project_id)
    if err then
      return log.error(err)
    end
    project_id = opts.project_id or project_id
    if not project_id then
      return M.projects(function()
        M.milestones(opts)
      end)
    end
    milestones.all(project_id, function(aerr, list)
      if aerr then
        return log.error(aerr)
      end
      show(list, opts.title)
    end)
  end)
end

--- Artifacts planned inside a milestone.
---@param milestone_id integer
function M.milestone_content(milestone_id)
  milestones.content(milestone_id, function(err, list)
    if err then
      return log.error(err)
    end
    if not list or #list == 0 then
      return log.warn("This sprint has no content yet")
    end
    M.artifacts({ artifacts = list, title = ("Sprint #%d content"):format(milestone_id) })
  end)
end

return M
