---@mod tuleap.ui.detail Artifact detail view
---
--- Read-only rendering of one artifact with its fields, follow-up comments and
--- linked artifacts, plus buffer-local mappings for every write operation.

local artifacts = require("tuleap.api.artifacts")
local config = require("tuleap.config")
local date = require("tuleap.util.date")
local render = require("tuleap.ui.render")
local trackers = require("tuleap.api.trackers")
local users = require("tuleap.api.users")
local window = require("tuleap.ui.window")

local M = {}

--- Fields already shown in the header, skipped in the generic field list.
local HEADER_FIELDS = {
  aid = true,
  atid = true,
  subon = true,
  subby = true,
  lud = true,
  luby = true,
  priority = true,
  burndown = true,
  cross = true,
  fieldset = true,
  column = true,
  staticrichtext = true,
  art_link = true,
  perm = true,
}

--- Icon keys that describe an item type, in match priority order. The other
--- `ui.icons` entries ("open", "date", ...) must never match a tracker name.
local TYPE_ICONS = { "epic", "story", "sprint", "release", "bug", "task" }

---@param icons table
---@param tracker_name string?
---@return string
local function icon_for(icons, tracker_name)
  local name = (tracker_name or ""):lower()
  for _, key in ipairs(TYPE_ICONS) do
    if icons[key] and name:find(key, 1, true) then
      return icons[key]
    end
  end
  return icons.task or ""
end

--- Pull the description out of the artifact values using the tracker semantics
--- when available, falling back to the first `text` field.
---@param artifact table
---@param tracker table?
---@return string?
local function description_of(artifact, tracker)
  local field = tracker and trackers.semantic_field(tracker, "description")
  for _, value in ipairs(artifact.values or {}) do
    if field and value.field_id == field.field_id then
      return render.strip_html(trackers.render_value(value, field))
    end
  end
  if not field then
    for _, value in ipairs(artifact.values or {}) do
      if value.type == "text" then
        return render.strip_html(trackers.render_value(value))
      end
    end
  end
  return nil
end

--- Tracker fields indexed by id, so artifact values can resolve their labels.
---@param tracker table?
---@return table<integer, table>
local function fields_by_id(tracker)
  local out = {}
  for _, field in ipairs((tracker or {}).fields or {}) do
    out[field.field_id] = field
  end
  return out
end

---@class tuleap.DetailState
---@field artifact table
---@field tracker table?
---@field changesets table[]?
---@field links table[]?

---@param state tuleap.DetailState
---@param width integer
---@return tuleap.Builder
local function build(state, width)
  local artifact = state.artifact
  local icons = config.options.ui.icons
  local builder = render.builder(width)

  local open = artifacts.is_open(artifact)
  local tracker_label = artifact.tracker and (artifact.tracker.label or artifact.tracker.item_name)
  local schema = fields_by_id(state.tracker)

  builder:line({
    { "  " .. icon_for(icons, tracker_label) .. " ", open and "TuleapOpen" or "TuleapClosed" },
    { artifacts.xref(artifact) .. "  ", "TuleapXref" },
    { artifacts.title(artifact), "TuleapTitle" },
  })
  builder:rule("─", width)

  local status = artifacts.status(artifact)
  builder:field("Status", ("%s %s"):format(open and icons.open or icons.closed, status ~= "" and status or "—"), {
    hl = open and "TuleapOpen" or "TuleapClosed",
  })
  builder:field("Tracker", tracker_label)
  builder:field(
    "Submitted",
    ("%s · %s"):format(users.label(artifact.submitted_by_user or artifact.submitted_by), date.relative(artifact.submitted_on))
  )
  builder:field("Updated", date.relative(artifact.last_modified_date))

  -- Fields already rendered in this header must not show up again below.
  local semantic_ids = {}
  for _, name in ipairs({ "title", "description", "status", "contributor" }) do
    local field = trackers.semantic_field(state.tracker or {}, name)
    if field then
      semantic_ids[field.field_id] = true
    end
  end

  local assignee = trackers.semantic_field(state.tracker or {}, "contributor")
  for _, value in ipairs(artifact.values or {}) do
    if assignee and value.field_id == assignee.field_id then
      builder:field("Assigned to", trackers.render_value(value, assignee), { hl = "TuleapUser" })
    end
  end

  -- ------------------------------------------------------------ description
  local description = description_of(artifact, state.tracker)
  if description and description ~= "" then
    builder:section("Description")
    builder:wrap(description, { indent = "  ", width = width })
  end

  -- ----------------------------------------------------------------- fields
  local shown = false
  for _, value in ipairs(artifact.values or {}) do
    local skip = HEADER_FIELDS[value.type] or value.type == "text" or semantic_ids[value.field_id]
    local rendered = skip and "" or trackers.render_value(value, schema[value.field_id])
    if not skip and rendered ~= "" and value.label then
      if not shown then
        builder:section("Fields")
        shown = true
      end
      builder:field(value.label, rendered, { width = 18 })
    end
  end

  -- --------------------------------------------------------------- comments
  if state.changesets then
    local comments = {}
    for _, changeset in ipairs(state.changesets) do
      local body = changeset.last_comment and changeset.last_comment.body
      if body and vim.trim(render.strip_html(body)) ~= "" then
        comments[#comments + 1] = changeset
      end
    end
    builder:section(("%s Comments (%d)"):format(config.options.ui.icons.comment, #comments))
    if #comments == 0 then
      builder:line({ { "  no comments yet", "TuleapHint" } })
    end
    for _, changeset in ipairs(comments) do
      local first = #builder.lines
      builder:line({
        { "  " .. users.label(changeset.submitted_by_details or changeset.submitted_by), "TuleapCommentAuthor" },
        { " · " .. date.relative(changeset.submitted_on), "TuleapDate" },
      })
      builder:wrap(render.strip_html(changeset.last_comment.body), {
        indent = "    ",
        hl = "TuleapCommentBody",
        width = width,
      })
      -- Anchor every row of the comment so the cursor can sit anywhere in it.
      for row = first, #builder.lines - 1 do
        builder.anchors[row] = { key = "comment", value = changeset.id }
      end
      builder:blank()
    end
  end

  -- ------------------------------------------------------------------ links
  if state.links and #state.links > 0 then
    builder:section("Linked artifacts")
    for _, link in ipairs(state.links) do
      builder:anchor("artifact", link.id)
      builder:line({
        { "  " .. (link.xref or ("#" .. tostring(link.id))) .. "  ", "TuleapXref" },
        { artifacts.title(link), "TuleapValue" },
      })
    end
  end

  return builder
end

--- Open the detail view for an artifact id.
---@param id integer
---@param opts {refresh: boolean?}?
function M.open(id, opts)
  opts = opts or {}
  local keys = config.options.keymaps.detail
  local win = window.open({
    title = ("Tuleap artifact #%d"):format(id),
    footer = config.options.ui.show_help_hint
        and ("%s edit  %s comment  %s close  %s attach  %s browser  %s help"):format(
          keys.edit or "-",
          keys.comment or "-",
          keys.close_artifact or "-",
          keys.attach or "-",
          keys.open_browser or "-",
          keys.help or "-"
        )
      or nil,
    filetype = "tuleap-artifact",
  })
  win:loading(("Loading artifact #%d …"):format(id))

  ---@type tuleap.DetailState
  local state = {}

  local function draw()
    if not win:valid() or not state.artifact then
      return
    end
    local builder = build(state, win.width)
    win:set_lines(builder.lines)
    win:highlight(builder.highlights)
    win.anchors = builder.anchors
    win:set_title(("%s  %s"):format(artifacts.xref(state.artifact), artifacts.title(state.artifact)))
  end

  local function load(refresh)
    artifacts.get(id, function(err, artifact)
      if err then
        return win:error(err)
      end
      state.artifact = artifact
      config.state.last_artifact_id = id
      draw()

      local tracker_id = artifact.tracker and artifact.tracker.id
      if tracker_id then
        trackers.get(tracker_id, function(_, tracker)
          state.tracker = tracker
          draw()
        end)
      end
      artifacts.changesets(id, function(_, changesets)
        state.changesets = changesets or {}
        draw()
      end)
      artifacts.links(id, "forward", function(_, links)
        state.links = links
        draw()
      end)
    end, { refresh = refresh })
  end

  local actions = require("tuleap.actions")

  win:map(keys.close, function()
    win:close()
  end, "Close")
  win:map(keys.refresh, function()
    require("tuleap.cache").invalidate()
    win:loading("Refreshing …")
    load(true)
  end, "Refresh")
  --- The comment the cursor sits in, if any.
  ---@return integer? changeset_id
  local function comment_at_cursor()
    if not win:valid() then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(win.win)[1] - 1
    local anchor = (win.anchors or {})[row]
    return anchor and anchor.key == "comment" and anchor.value or nil
  end

  --- Browser URL of a specific follow-up comment.
  ---@param changeset_id integer
  ---@return string
  local function comment_url(changeset_id)
    return ("%s#followup_%d"):format(artifacts.url(state.artifact or id), changeset_id)
  end

  win:map(keys.edit, function()
    local changeset = comment_at_cursor()
    if changeset then
      -- Tuleap's REST API exposes no route for editing a follow-up comment
      -- (`/artifacts/{id}/changesets` is read-only), so say so plainly rather
      -- than open a form that could not be saved.
      return require("tuleap.util.log").warn(
        "Tuleap's REST API cannot edit an existing comment.\n"
          .. ("Press %s to open this one in the browser, or %s to add a new comment."):format(
            keys.open_browser or "o",
            keys.comment or "c"
          )
      )
    end
    actions.edit(id, { on_done = function()
      load(true)
    end })
  end, "Edit fields")
  win:map(keys.comment, function()
    actions.comment(id, { on_done = function()
      load(true)
    end })
  end, "Add comment")
  win:map(keys.close_artifact, function()
    actions.close(id, { on_done = function()
      load(true)
    end })
  end, "Close artifact")
  win:map(keys.attach, function()
    actions.attach(id, { on_done = function()
      load(true)
    end })
  end, "Attach to epic or sprint")
  win:map(keys.delete, function()
    actions.delete(id, { on_done = function()
      win:close()
    end })
  end, "Delete artifact")
  win:map(keys.open_browser, function()
    local changeset = comment_at_cursor()
    if changeset then
      return actions.open_url(comment_url(changeset))
    end
    actions.open_in_browser(state.artifact or id)
  end, "Open in browser")
  win:map(keys.yank_url, function()
    local changeset = comment_at_cursor()
    if changeset then
      local url = comment_url(changeset)
      vim.fn.setreg(vim.v.register or '"', url)
      vim.fn.setreg("+", url)
      return require("tuleap.util.log").info("Yanked %s", url)
    end
    actions.yank_url(state.artifact or id)
  end, "Yank URL")
  win:map(keys.links, function()
    local row = vim.api.nvim_win_get_cursor(win.win)[1] - 1
    local anchor = (win.anchors or {})[row]
    if anchor and anchor.key == "artifact" then
      win:close()
      M.open(anchor.value)
    else
      require("tuleap.util.log").info("Put the cursor on a linked artifact first")
    end
  end, "Follow link")
  win:map(keys.help, function()
    M.help()
  end, "Help")

  load(opts.refresh)
  return win
end

--- Cheat sheet for the detail view.
function M.help()
  local keys = config.options.keymaps.detail
  local rows = {
    { keys.close, "close the view" },
    { keys.refresh, "refetch from Tuleap" },
    { keys.edit, "edit fields in a form" },
    { keys.comment, "post a follow-up comment" },
    { keys.close_artifact, "move to a closed status" },
    { keys.attach, "attach to an epic or a sprint" },
    { keys.delete, "delete the artifact (site admin only)" },
    { keys.open_browser, "open in the browser (the comment under the cursor, if any)" },
    { keys.yank_url, "yank the URL (of the comment under the cursor, if any)" },
    { keys.links, "follow the linked artifact under the cursor" },
    { keys.help, "this help" },
  }
  local builder = render.builder(50)
  builder:line({ { "  Tuleap artifact view", "TuleapTitle" } })
  builder:rule("─", 50)
  for _, row in ipairs(rows) do
    if row[1] then
      builder:field(row[1], row[2], { width = 8 })
    end
  end
  local win = window.open({ title = "Keymaps", width = 56, height = #builder.lines + 2 })
  win:set_lines(builder.lines)
  win:highlight(builder.highlights)
end

return M
