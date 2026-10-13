---@mod tuleap.api.trackers Tracker schemas
---
--- In Tuleap everything is an *artifact* inside a *tracker*. "Issue", "epic"
--- and "sprint" are therefore just trackers, which is why `config.trackers`
--- maps our vocabulary onto the ones your instance actually uses.

local client = require("tuleap.api.client")
local config = require("tuleap.config")
local projects = require("tuleap.api.projects")

local M = {}

--- Field types the form view knows how to edit.
M.EDITABLE_TYPES = {
  string = true,
  text = true,
  int = true,
  float = true,
  date = true,
  sb = true,
  msb = true,
  cb = true,
  rb = true,
  tbl = true,
  computed = true,
}

--- Field types that are free text rather than a bound list.
M.SCALAR_TYPES = { string = true, text = true, int = true, float = true, date = true, computed = true }

---@param project_id integer
---@param cb fun(err: string?, trackers: table[]?)
function M.list(project_id, cb)
  client.paginate(("/projects/%d/trackers"):format(project_id), { representation = "minimal" }, cb, {
    cache_ttl = 600,
  })
end

---@param tracker_id integer
---@param cb fun(err: string?, tracker: table?)
function M.get(tracker_id, cb)
  client.get(("/trackers/%d"):format(tracker_id), nil, cb, { cache_ttl = 600 })
end

--- Resolve a configured key ("issue", "epic", ...) or a raw id/shortname to a
--- tracker id inside the current project.
---@param key string|integer
---@param cb fun(err: string?, tracker_id: integer?)
function M.resolve(key, cb)
  local wanted = config.options.trackers[key] or key
  if type(wanted) == "number" then
    return cb(nil, wanted)
  end
  if type(wanted) == "string" and wanted:match("^%d+$") then
    return cb(nil, tonumber(wanted))
  end

  projects.current(function(err, project_id)
    if err then
      return cb(err)
    end
    if not project_id then
      return cb("no project selected — run `:Tuleap projects` first")
    end
    M.list(project_id, function(list_err, trackers)
      if list_err then
        return cb(list_err)
      end
      local needle = tostring(wanted):lower()
      for _, tracker in ipairs(trackers or {}) do
        if
          (tracker.item_name or ""):lower() == needle
          or (tracker.label or ""):lower() == needle
        then
          return cb(nil, tracker.id)
        end
      end
      -- Second pass: accept a partial label match ("bug" -> "Bugs").
      for _, tracker in ipairs(trackers or {}) do
        if (tracker.label or ""):lower():find(needle, 1, true) then
          return cb(nil, tracker.id)
        end
      end
      cb(
        ("no tracker %q in project %d — adjust `trackers.%s` in your setup"):format(
          tostring(wanted),
          project_id,
          tostring(key)
        )
      )
    end)
  end)
end

---@param tracker table
---@param ident string|integer field name, label or id
---@return table?
function M.field(tracker, ident)
  if not tracker or type(tracker.fields) ~= "table" then
    return nil
  end
  for _, field in ipairs(tracker.fields) do
    if
      field.field_id == ident
      or field.name == ident
      or field.label == ident
      or (type(ident) == "string" and (field.name or ""):lower() == ident:lower())
    then
      return field
    end
  end
  return nil
end

---@param tracker table
---@param name string semantic name: title, description, status, contributor
---@return table? field
function M.semantic_field(tracker, name)
  local semantics = tracker and tracker.semantics
  local entry = semantics and semantics[name]
  if type(entry) ~= "table" or not entry.field_id then
    return nil
  end
  return M.field(tracker, entry.field_id)
end

---@param tracker table
---@return table? field, integer[] open_value_ids
function M.status(tracker)
  local field = M.semantic_field(tracker, "status")
  local open = {}
  local semantics = tracker and tracker.semantics and tracker.semantics.status
  if type(semantics) == "table" and type(semantics.open_values) == "table" then
    open = semantics.open_values
  end
  return field, open
end

--- Values of the status field that mean "closed".
---@param tracker table
---@return table[] values, table? field
function M.closed_values(tracker)
  local field, open = M.status(tracker)
  if not field then
    return {}, nil
  end
  local open_set = {}
  for _, id in ipairs(open) do
    open_set[id] = true
  end
  local out = {}
  for _, value in ipairs(field.values or {}) do
    if not open_set[value.id] and not value.is_hidden then
      out[#out + 1] = value
    end
  end
  return out, field
end

--- Best guess at the effort field used by burndown/burnup charts.
---@param tracker table
---@return table?
function M.effort_field(tracker)
  local candidates = {
    "remaining_effort",
    "initial_effort",
    "story_points",
    "effort",
    "capacity",
  }
  for _, name in ipairs(candidates) do
    local field = M.field(tracker, name)
    if field then
      return field
    end
  end
  for _, field in ipairs((tracker or {}).fields or {}) do
    local label = (field.label or ""):lower()
    if label:find("effort") or label:find("points") then
      return field
    end
  end
  return nil
end

--- Whether a form may offer this field.
---
--- Tuleap spells the write permission `update`, `create` or `submit` depending
--- on the version, and omits `permissions` entirely on some representations.
--- A missing list means "unknown", not "read only": hiding every field would
--- leave the user with an empty form, so we let the server reject the write
--- instead of guessing.
---@param field table
---@return boolean
function M.is_writable(field)
  local perms = field.permissions
  if type(perms) ~= "table" or #perms == 0 then
    return true
  end
  for _, permission in ipairs(perms) do
    if permission == "update" or permission == "create" or permission == "submit" then
      return true
    end
  end
  return false
end

--- Fields the form view should offer, in tracker order.
---@param tracker table
---@param opts {required_only: boolean?}?
---@return table[]
function M.editable_fields(tracker, opts)
  opts = opts or {}
  local out = {}
  for _, field in ipairs((tracker or {}).fields or {}) do
    if M.EDITABLE_TYPES[field.type] and M.is_writable(field) then
      if not opts.required_only or field.required then
        out[#out + 1] = field
      end
    end
  end
  return out
end

--- Build the `values` entry the REST API expects for one field.
---@param field table
---@param value any string for scalars, id or list of ids for bound fields
---@return table?
function M.value_payload(field, value)
  local id = field.field_id
  if field.type == "text" then
    return { field_id = id, value = { content = tostring(value or ""), format = "text" } }
  elseif field.type == "string" or field.type == "date" then
    return { field_id = id, value = tostring(value or "") }
  elseif field.type == "int" or field.type == "float" or field.type == "computed" then
    local number = tonumber(value)
    if field.type == "computed" then
      return { field_id = id, manual_value = number, is_autocomputed = number == nil }
    end
    return { field_id = id, value = number }
  elseif field.type == "sb" or field.type == "rb" or field.type == "msb" or field.type == "cb" then
    local ids = type(value) == "table" and value or { value }
    local clean = {}
    for _, item in ipairs(ids) do
      local n = tonumber(item)
      if n then
        clean[#clean + 1] = n
      end
    end
    return { field_id = id, bind_value_ids = clean }
  elseif field.type == "tbl" then
    local list = type(value) == "table" and value or { value }
    local out = {}
    for _, item in ipairs(list) do
      if item ~= nil and item ~= "" then
        out[#out + 1] = tonumber(item) and { id = tonumber(item) } or { label = tostring(item) }
      end
    end
    return { field_id = id, bind_value_objects = out }
  end
  return nil
end

--- Labels of a bound field's values, resolved against the tracker schema.
---
--- Artifact representations sometimes carry only `bind_value_ids` with no
--- labels attached; without the field definition those render as nothing,
--- which is what used to leave Status and Assignee blank in the edit form.
---@param ids integer[]
---@param field table?
---@return string[]
local function labels_for_ids(ids, field)
  local by_id = {}
  for _, value in ipairs((field or {}).values or {}) do
    by_id[value.id] = value.label or value.display_name or value.username
  end
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = by_id[id] or tostring(id)
  end
  return out
end

---@param item any
---@return string?
local function item_label(item)
  if type(item) ~= "table" then
    return item ~= nil and tostring(item) or nil
  end
  return item.label
    or item.display_name
    or item.username
    or item.real_name
    or (item.id ~= nil and tostring(item.id) or nil)
end

--- Human readable rendering of an artifact field value as returned by
--- `GET /artifacts/{id}`.
---
--- Tuleap's field value representations are not uniform — text fields nest
--- `{content, format}` on some versions and keep `value` flat on others, list
--- fields expose `values`, `bind_value_ids` or both — so every known shape is
--- handled here rather than at each call site.
---@param value table
---@param field table? tracker field definition, used to resolve bound ids
---@return string
function M.render_value(value, field)
  if type(value) ~= "table" then
    return tostring(value or "")
  end

  -- Bound lists first: they are the ones that lose their labels.
  if type(value.values) == "table" and #value.values > 0 then
    local labels = {}
    for _, item in ipairs(value.values) do
      labels[#labels + 1] = item_label(item)
    end
    return table.concat(labels, ", ")
  end
  if type(value.bind_value_ids) == "table" and #value.bind_value_ids > 0 then
    return table.concat(labels_for_ids(value.bind_value_ids, field), ", ")
  end
  if type(value.bind_value_objects) == "table" and #value.bind_value_objects > 0 then
    local labels = {}
    for _, item in ipairs(value.bind_value_objects) do
      labels[#labels + 1] = item_label(item)
    end
    return table.concat(labels, ", ")
  end

  -- Scalars, flat or nested.
  if type(value.value) == "table" then
    if value.value.content ~= nil then
      return tostring(value.value.content)
    end
    local label = item_label(value.value)
    if label then
      return label
    end
  elseif value.value ~= nil then
    return tostring(value.value)
  end

  if value.content ~= nil then
    return tostring(value.content)
  end
  if value.manual_value ~= nil then
    return tostring(value.manual_value)
  end
  if value.is_autocomputed then
    return "(autocomputed)"
  end

  if type(value.links) == "table" and #value.links > 0 then
    local refs = {}
    for _, link in ipairs(value.links) do
      refs[#refs + 1] = tostring(link.id)
    end
    return table.concat(refs, ", ")
  end
  if type(value.file_descriptions) == "table" and #value.file_descriptions > 0 then
    local names = {}
    for _, file in ipairs(value.file_descriptions) do
      names[#names + 1] = file.name or "file"
    end
    return table.concat(names, ", ")
  end
  return ""
end

--- Bound value ids currently set on an artifact field value.
---@param value table?
---@return integer[]
function M.selected_ids(value)
  local out = {}
  if type(value) ~= "table" then
    return out
  end
  if type(value.bind_value_ids) == "table" then
    for _, id in ipairs(value.bind_value_ids) do
      out[#out + 1] = id
    end
    return out
  end
  for _, item in ipairs(value.values or {}) do
    if type(item) == "table" and item.id then
      out[#out + 1] = item.id
    end
  end
  return out
end

return M
