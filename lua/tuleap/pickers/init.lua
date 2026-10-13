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

--- Columns shown for one artifact in a picker row: `{text, highlight}` pairs.
---
--- Pure on purpose — it is the part worth testing, while turning columns into
--- a padded string is telescope's job and only works inside a live picker.
---@param artifact table
---@return {[1]: string, [2]: string}[]
function M.entry_columns(artifact)
  local icons = config.options.ui.icons
  local open = artifacts.is_open(artifact)
  local hl = open and "TuleapOpen" or "TuleapClosed"

  local columns = { { open and icons.open or icons.closed, hl } }
  if config.options.picker.show_id then
    columns[#columns + 1] = { artifacts.xref(artifact), "TuleapXref" }
  end
  columns[#columns + 1] = { artifacts.status(artifact), hl }
  columns[#columns + 1] = { artifacts.title(artifact), "TuleapValue" }
  return columns
end

--- Text used for fuzzy matching a picker row.
---@param artifact table
---@return string
function M.entry_ordinal(artifact)
  return ("%s %s %s"):format(
    artifacts.xref(artifact),
    artifacts.status(artifact),
    artifacts.title(artifact)
  )
end

--- Build the Telescope `entry_maker` for a list of artifacts. Column widths are
--- computed from the whole list so the status column lines up.
---
--- Exposed so a custom picker can reuse the same entry shape.
---@param list table[]
---@return fun(artifact: table): table
function M.entry_maker(list)
  local ts = telescope()
  if not ts then
    return function(artifact)
      return {
        value = artifact,
        ordinal = M.entry_ordinal(artifact),
        display = M.entry_ordinal(artifact),
      }
    end
  end

  local id_width, status_width = 4, 6
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
    return {
      value = artifact,
      ordinal = M.entry_ordinal(artifact),
      display = function()
        return displayer(M.entry_columns(artifact))
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
    map({ "i", "n" }, "<M-a>", with_selection(function(id)
      actions.attach(id, { on_done = reload })
    end))
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
            entry_maker = M.entry_maker(list),
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

--- Whether `artifact` is assigned to `me`, according to the tracker's
--- contributor semantic.
---
--- User-bound list fields expose the user id as the bind value id, but some
--- representations only carry usernames, so both are checked.
---@param artifact table
---@param field table contributor field definition
---@param me table
---@return boolean
local function assigned_to_me(artifact, field, me)
  for _, value in ipairs(artifact.values or {}) do
    if value.field_id == field.field_id then
      for _, id in ipairs(trackers.selected_ids(value)) do
        if tostring(id) == tostring(me.id) then
          return true
        end
      end
      for _, item in ipairs(value.values or {}) do
        if type(item) == "table" then
          if
            (item.username and item.username == me.username)
            or (item.id and tostring(item.id) == tostring(me.id))
            or (item.display_name and item.display_name == me.display_name)
            or (item.email and me.email and item.email == me.email)
          then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Artifacts assigned to the authenticated user across every configured tracker.
---
--- Two strategies, in order:
---   1. a server side TQL query on the tracker's *own* contributor field name
---      (it is rarely called `assigned_to` on real instances), and
---   2. a client side filter over the tracker's artifacts.
---
--- The fallback also runs when the query *succeeds but matches nothing*, which
--- is what made this command look empty: a TQL query that Tuleap accepts but
--- cannot satisfy — because the field is not the one it indexes, or the
--- instance does not implement `MYSELF()` — returns an empty list rather than
--- an error.
function M.mine()
  local ts = telescope()
  if not ts then
    return
  end
  users.self(function(uerr, me)
    if uerr then
      return log.error("Could not identify you: %s", uerr)
    end

    local keys = {}
    for key in pairs(config.options.trackers) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    if #keys == 0 then
      return log.warn("No tracker configured — set `trackers` in your setup")
    end

    local collected, seen = {}, {}
    local pending = #keys
    local searched, unresolved, no_semantic = 0, {}, {}

    ---@param list table[]?
    local function collect(list)
      for _, artifact in ipairs(list or {}) do
        if artifact.id and not seen[artifact.id] then
          seen[artifact.id] = true
          collected[#collected + 1] = artifact
        end
      end
    end

    local function done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if #collected > 0 then
        return M.artifacts({
          artifacts = collected,
          title = ("Assigned to %s"):format(users.label(me)),
        })
      end

      -- Nothing found: say why, because "empty" alone is not actionable.
      local reasons = {}
      if #unresolved > 0 then
        reasons[#reasons + 1] = ("unresolved trackers: %s"):format(table.concat(unresolved, ", "))
      end
      if #no_semantic > 0 then
        reasons[#reasons + 1] =
          ("no assignee semantic on: %s"):format(table.concat(no_semantic, ", "))
      end
      log.warn(
        "Nothing assigned to %s in %d tracker%s.%s\nRun `:Tuleap doctor` to see what was searched.",
        users.label(me),
        searched,
        searched == 1 and "" or "s",
        #reasons > 0 and ("\n" .. table.concat(reasons, "\n")) or ""
      )
    end

    for _, key in ipairs(keys) do
      trackers.resolve(key, function(rerr, tracker_id)
        if rerr then
          unresolved[#unresolved + 1] = key
          return done()
        end
        trackers.get(tracker_id, function(terr, tracker)
          if terr then
            unresolved[#unresolved + 1] = key
            return done()
          end
          searched = searched + 1

          local field = trackers.semantic_field(tracker, "contributor")
          if not field then
            no_semantic[#no_semantic + 1] = tracker.label or key
            return done()
          end

          local function client_side()
            artifacts.list(tracker_id, {}, function(_, all)
              local mine = {}
              for _, artifact in ipairs(all or {}) do
                if assigned_to_me(artifact, field, me) then
                  mine[#mine + 1] = artifact
                end
              end
              log.dev("%s: %d/%d artifacts assigned to me", key, #mine, #(all or {}))
              collect(mine)
              done()
            end)
          end

          local query = ("%s = MYSELF()"):format(field.name or "assigned_to")
          artifacts.list(tracker_id, { expert_query = query }, function(qerr, list)
            if qerr or #(list or {}) == 0 then
              log.dev("%s: TQL %q returned %s, falling back", key, query, qerr or "nothing")
              return client_side()
            end
            collect(list)
            done()
          end)
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

--- Pick one artifact of a tracker and hand it back, instead of opening it.
--- Used by the attach flow.
---@param opts {kind: string?, title: string?, exclude: integer?}
---@param cb fun(artifact: table)
function M.select_artifact(opts, cb)
  opts = opts or {}
  local ts = telescope()
  if not ts then
    return
  end
  trackers.resolve(opts.kind or "epic", function(err, tracker_id)
    if err then
      return log.error(err)
    end
    artifacts.list(tracker_id, {}, function(lerr, list)
      if lerr then
        return log.error(lerr)
      end
      list = vim.tbl_filter(function(artifact)
        return artifact.id ~= opts.exclude
      end, list or {})
      if #list == 0 then
        return log.warn("No %s to attach to", tostring(opts.kind or "epic"))
      end
      ts.pickers
        .new(picker_opts(), {
          prompt_title = opts.title or "Pick an artifact",
          finder = ts.finders.new_table({ results = list, entry_maker = M.entry_maker(list) }),
          sorter = ts.conf.generic_sorter({}),
          previewer = config.options.picker.preview and artifact_previewer(ts) or nil,
          attach_mappings = function(prompt_bufnr)
            ts.actions.select_default:replace(function()
              local entry = ts.state.get_selected_entry()
              ts.actions.close(prompt_bufnr)
              if entry then
                cb(entry.value)
              end
            end)
            return true
          end,
        })
        :find()
    end)
  end)
end

--- Pick one milestone and hand it back.
---@param opts {title: string?}?
---@param cb fun(milestone: table)
function M.select_milestone(opts, cb)
  opts = opts or {}
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
        M.select_milestone(opts, cb)
      end)
    end
    milestones.all(project_id, function(aerr, list)
      if aerr then
        return log.error(aerr)
      end
      if not list or #list == 0 then
        return log.warn("No milestone found — is the Agile Dashboard enabled?")
      end
      ts.pickers
        .new(picker_opts(), {
          prompt_title = opts.title or "Pick a sprint",
          finder = ts.finders.new_table({
            results = list,
            entry_maker = function(milestone)
              return {
                value = milestone,
                ordinal = milestone.label or tostring(milestone.id),
                display = ("%-44s %s"):format(
                  milestones.label(milestone),
                  milestone.semantic_status or ""
                ),
              }
            end,
          }),
          sorter = ts.conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            ts.actions.select_default:replace(function()
              local entry = ts.state.get_selected_entry()
              ts.actions.close(prompt_bufnr)
              if entry then
                cb(entry.value)
              end
            end)
            return true
          end,
        })
        :find()
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
