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

---@param field table
---@return boolean
function M.is_writable(field)
  local perms = field.permissions or {}
  return vim.tbl_contains(perms, "update") or vim.tbl_contains(perms, "create")
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

--- Human readable rendering of an artifact field value as returned by
--- `GET /artifacts/{id}?values=all`.
---@param value table
---@return string
function M.render_value(value)
  if type(value) ~= "table" then
    return tostring(value or "")
  end
  if value.value ~= nil and type(value.value) ~= "table" then
    return tostring(value.value)
  end
  if type(value.value) == "table" and value.value.content then
    return tostring(value.value.content)
  end
  if type(value.values) == "table" then
    local labels = {}
    for _, item in ipairs(value.values) do
      labels[#labels + 1] = type(item) == "table"
          and (item.label or item.display_name or item.username or tostring(item.id))
        or tostring(item)
    end
    return table.concat(labels, ", ")
  end
  if value.manual_value ~= nil then
    return tostring(value.manual_value)
  end
  if value.is_autocomputed and value.value == nil then
    return "(autocomputed)"
  end
  if type(value.links) == "table" then
    local refs = {}
    for _, link in ipairs(value.links) do
      refs[#refs + 1] = tostring(link.id)
    end
    return table.concat(refs, ", ")
  end
  if type(value.file_descriptions) == "table" then
    local names = {}
    for _, file in ipairs(value.file_descriptions) do
      names[#names + 1] = file.name or "file"
    end
    return table.concat(names, ", ")
  end
  return ""
end

return M
