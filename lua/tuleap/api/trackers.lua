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

--- Field types bound to a list of values.
M.LIST_TYPES = { sb = true, msb = true, cb = true, rb = true, tbl = true }

--- Tuleap's own id for the "None" entry of every list binding. It is a value
--- like any other in a payload, and never a user.
M.NONE_VALUE_ID = 100

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

--- Strip case and punctuation: "User Stories" -> "userstories".
---@param text any
---@return string
local function normalise(text)
  return (tostring(text or ""):lower():gsub("[^%w]+", ""))
end

--- Crude singularisation, enough for tracker names: "userstories" -> "userstory",
--- "bugs" -> "bug", "releases" -> "release". Without it a `story` key never
--- matches a tracker labelled "User Stories".
---@param text string
---@return string
local function singular(text)
  if text:match("ies$") then
    return (text:gsub("ies$", "y"))
  end
  if text:match("sses$") or text:match("xes$") or text:match("ches$") or text:match("shes$") then
    return (text:gsub("es$", ""))
  end
  if text:match("s$") and not text:match("ss$") then
    return (text:gsub("s$", ""))
  end
  return text
end

--- How well a pair of names matches a wanted one. 0 means no match.
---
--- Trackers are identified by `item_name` plus `label` and fields by `name`
--- plus `label`, so both go through the same tolerant comparison.
---@param primary any shortname: `item_name` or `name`
---@param secondary any human label
---@param needle string already normalised
---@return integer
local function name_score(primary, secondary, needle)
  local item, label = normalise(primary), normalise(secondary)
  local needle_s = singular(needle)

  if item == needle then
    return 100
  elseif label == needle then
    return 90
  elseif singular(item) == needle_s then
    return 80
  elseif singular(label) == needle_s then
    return 70
  elseif #needle_s >= 3 and singular(label):find(needle_s, 1, true) then
    return 50
  elseif #needle_s >= 3 and singular(item):find(needle_s, 1, true) then
    return 40
  end
  return 0
end

--- How well a tracker matches a wanted name. 0 means no match.
---@param tracker table
---@param needle string already normalised
---@return integer
local function match_score(tracker, needle)
  return name_score(tracker.item_name, tracker.label, needle)
end

--- Resolve a configured key ("issue", "epic", ...) or a raw id/shortname to a
--- tracker id inside the current project.
---
--- Matching is tolerant of case, punctuation and plurals, so the default
--- `story` key finds a tracker labelled "User Stories".
---@param key string|integer
---@param cb fun(err: string?, tracker_id: integer?)
function M.resolve(key, cb)
  local wanted = config.options.trackers[key]
  if wanted == nil then
    wanted = key
  end
  if type(wanted) == "number" then
    return cb(nil, wanted)
  end
  if type(wanted) == "string" and wanted:match("^%d+$") then
    return cb(nil, tonumber(wanted))
  end

  -- A key may list several candidate names: Tuleap's templates disagree on
  -- what the issue tracker is called, so `{ "issue", "bug" }` fits both.
  local candidates = type(wanted) == "table" and wanted or { wanted }
  if #candidates == 0 then
    return cb(("`trackers.%s` is an empty list"):format(tostring(key)))
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

      -- Candidates are tried strictly in order: the first name that matches
      -- anything wins, even if a later one would match more exactly. That is
      -- what makes `{ "issue", "bug" }` reach a tracker labelled "Issues"
      -- rather than one whose shortname happens to be "bug".
      for _, candidate in ipairs(candidates) do
        local needle = normalise(candidate)
        local best, best_score
        for _, tracker in ipairs(trackers or {}) do
          local score = match_score(tracker, needle)
          -- On a tie prefer the shorter name: "Issues" over "Known Issues".
          if
            score > 0
            and (
              not best_score
              or score > best_score
              or (score == best_score and #(tracker.label or "") < #(best.label or ""))
            )
          then
            best, best_score = tracker, score
          end
        end
        if best then
          return cb(nil, best.id)
        end
      end

      -- Nothing matched: name what *is* available so the fix is obvious.
      local available = {}
      for _, tracker in ipairs(trackers or {}) do
        available[#available + 1] = ("%s (%s, #%d)"):format(
          tracker.label or "?",
          tracker.item_name or "?",
          tracker.id
        )
      end
      cb(
        ("no tracker matching %q in project %d.\nSet `trackers.%s` to one of: %s"):format(
          table.concat(candidates, "/"),
          project_id,
          tostring(key),
          #available > 0 and table.concat(available, ", ") or "(none visible)"
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

--- The field playing a configured role, found by name.
---
--- Some fields every instance has are not covered by Tuleap's semantics — the
--- list of users involved in an artifact is one — so `config.fields` names
--- them. A candidate is a field id, a name or a label, matched as tolerantly
--- as a tracker name is, and candidates are tried in order.
---@param tracker table
---@param role string key of `config.options.fields`, e.g. "involved"
---@param opts {list: boolean?}? `list` rejects anything but a bound list field
---@return table?
function M.configured_field(tracker, role, opts)
  opts = opts or {}
  local wanted = (config.options.fields or {})[role]
  if not wanted then
    return nil
  end

  ---@param field table?
  ---@return boolean
  local function usable(field)
    return field ~= nil and (not opts.list or M.LIST_TYPES[field.type] == true)
  end

  for _, candidate in ipairs(type(wanted) == "table" and wanted or { wanted }) do
    local id = tonumber(candidate)
    if id then
      local field = M.field(tracker, id)
      if usable(field) then
        return field
      end
    else
      local needle = normalise(candidate)
      local best, best_score
      for _, field in ipairs((tracker or {}).fields or {}) do
        local score = usable(field) and name_score(field.name, field.label, needle) or 0
        -- On a tie prefer the shorter label, as tracker matching does.
        if
          score > 0
          and (
            not best_score
            or score > best_score
            or (score == best_score and #(field.label or "") < #(best.label or ""))
          )
        then
          best, best_score = field, score
        end
      end
      if best then
        return best
      end
    end
  end
  return nil
end

--- The field listing the users involved in an artifact.
---
--- Only a bound list is accepted: a text field that happens to be called
--- "Involved" would otherwise be written as a list of bind value ids.
---@param tracker table
---@return table?
function M.involved_field(tracker)
  return M.configured_field(tracker, "involved", { list = true })
end

--- The field holding an artifact's category.
---
--- Any field type qualifies: it is only ever written through the form, which
--- knows how to write a text field as well as a list.
---@param tracker table
---@return table?
function M.category_field(tracker)
  return M.configured_field(tracker, "category")
end

---@param tracker table
---@return table? field, integer[] open_value_ids
--- Keys Tuleap has used for the list of open status values.
---
--- Current versions answer `semantics.status.value_ids`; the others are kept
--- for older instances. Missing `value_ids` was why every tracker looked as if
--- it had no open status at all.
M.OPEN_VALUE_KEYS = { "value_ids", "open_values", "open_value_ids", "open", "values" }

---@param tracker table
---@return table? field, integer[] open_value_ids, string? source_key
function M.status(tracker)
  local field = M.semantic_field(tracker, "status")
  local semantics = tracker and tracker.semantics and tracker.semantics.status

  local raw, source = {}, nil
  if type(semantics) == "table" then
    for _, key in ipairs(M.OPEN_VALUE_KEYS) do
      if type(semantics[key]) == "table" and #semantics[key] > 0 then
        raw, source = semantics[key], key
        break
      end
    end
  end

  -- The list holds plain ids on most versions and objects on others.
  local ids = {}
  for _, value in ipairs(raw) do
    local id = type(value) == "table" and value.id or value
    if id ~= nil then
      ids[#ids + 1] = id
    end
  end
  return field, ids, source
end

--- Values of the status field that mean "closed".
---
--- When the tracker exposes no list of open values the two cannot be told
--- apart, so every value is returned together with `unknown = true` and the
--- caller is expected to say so rather than silently present "New" as a way
--- to close an artifact.
---@param tracker table
---@return table[] values, table? field, boolean unknown
function M.closed_values(tracker)
  local field, open = M.status(tracker)
  if not field then
    return {}, nil, false
  end

  local visible = {}
  for _, value in ipairs(field.values or {}) do
    if not value.is_hidden then
      visible[#visible + 1] = value
    end
  end

  if #open == 0 then
    return visible, field, true
  end

  local open_set = {}
  for _, id in ipairs(open) do
    open_set[id] = true
  end
  local out = {}
  for _, value in ipairs(visible) do
    if not open_set[value.id] then
      out[#out + 1] = value
    end
  end
  return out, field, false
end

--- The field holding an item's effort estimate.
---
--- The tracker's own semantics are authoritative and are consulted first:
--- `initial_effort` is what planning and the burndown scope use, and it is
--- what a form should offer for editing. Name guessing is only a fallback, and
--- it used to win — picking "Remaining Effort" over the declared estimate, or
--- a read-only field that then vanished from the form entirely.
---@param tracker table
---@param opts {writable: boolean?, mode: "create"|"update"|nil}? only consider fields a form could edit
---@return table?
function M.effort_field(tracker, opts)
  opts = opts or {}
  local semantics = (tracker or {}).semantics or {}

  ---@param field table?
  ---@return table?
  local function usable(field)
    if not field then
      return nil
    end
    if opts.writable and not (M.EDITABLE_TYPES[field.type] and M.is_writable(field, opts.mode)) then
      return nil
    end
    return field
  end

  local ordered = {}
  if type(semantics.initial_effort) == "table" and semantics.initial_effort.field_id then
    ordered[#ordered + 1] = M.field(tracker, semantics.initial_effort.field_id)
  end
  if type(semantics.progress) == "table" then
    ordered[#ordered + 1] = M.field(tracker, semantics.progress.total_effort_field_id)
    ordered[#ordered + 1] = M.field(tracker, semantics.progress.remaining_effort_field_id)
  end
  for _, name in ipairs({ "initial_effort", "story_points", "effort", "capacity", "remaining_effort" }) do
    ordered[#ordered + 1] = M.field(tracker, name)
  end
  for _, field in ipairs((tracker or {}).fields or {}) do
    local label = (field.label or ""):lower()
    if label:find("effort") or label:find("points") or label:find("capacity") then
      ordered[#ordered + 1] = field
    end
  end

  for _, field in ipairs(ordered) do
    local ok = usable(field)
    if ok then
      return ok
    end
  end
  return nil
end

--- Permission names that allow writing a field, per operation. Tuleap spells
--- the create permission `create` on some versions and `submit` on others.
local WRITE_PERMISSIONS = {
  create = { create = true, submit = true },
  update = { update = true },
  any = { create = true, submit = true, update = true },
}

--- Whether a form may offer this field for `mode`.
---
--- The distinction matters: a field can be updatable but not settable at
--- creation time — Tuleap's own Scrum template does this with Status — and
--- sending it in a POST fails the *whole* creation with "You are not allowed
--- to update the field Status".
---
--- A missing `permissions` list means "unknown", not "read only": hiding every
--- field would leave an empty form, so the server is left to object instead.
---@param field table
---@param mode "create"|"update"|nil nil means either
---@return boolean
function M.is_writable(field, mode)
  local perms = field.permissions
  if type(perms) ~= "table" or #perms == 0 then
    return true
  end
  local allowed = WRITE_PERMISSIONS[mode or "any"] or WRITE_PERMISSIONS.any
  for _, permission in ipairs(perms) do
    if allowed[permission] then
      return true
    end
  end
  return false
end

--- Fields the form view should offer, in tracker order.
---@param tracker table
---@param opts {required_only: boolean?, mode: "create"|"update"|nil}?
---@return table[]
function M.editable_fields(tracker, opts)
  opts = opts or {}
  local out = {}
  for _, field in ipairs((tracker or {}).fields or {}) do
    if M.EDITABLE_TYPES[field.type] and M.is_writable(field, opts.mode) then
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
---@param opts {format: string?}? text format to send back ("text"|"html"|"commonmark")
---@return table?
function M.value_payload(field, value, opts)
  local id = field.field_id
  if field.type == "text" then
    return {
      field_id = id,
      value = { content = tostring(value or ""), format = (opts or {}).format or "text" },
    }
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

--- The most human-readable name of a bound value.
---
--- User-bound values carry the bare username in `label` ("cqb") and the full
--- name in `user_reference.real_name` ("PIAULT Christophe 00023610 (cqb)").
--- The full name is what artifact values render as, so it is what forms show
--- too — otherwise editing an artifact rewrites the assignee behind your back.
---@param value table|string|number
---@return string
function M.value_display(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local ref = value.user_reference
  if type(ref) == "table" then
    return ref.real_name or ref.display_name or ref.username or value.label or tostring(value.id)
  end
  return value.display_name
    or value.label
    or value.username
    or value.real_name
    or tostring(value.id)
end

--- Every string that identifies a bound value, for matching user input.
---
--- Tuleap describes the same value differently in a tracker definition and in
--- an artifact payload, so a form that renders one spelling must accept all of
--- them when reading the text back.
---@param value table|string|number
---@return string[]
function M.value_aliases(value)
  local out, seen = {}, {}
  local function add(text)
    if type(text) == "string" and text ~= "" and not seen[text:lower()] then
      seen[text:lower()] = true
      out[#out + 1] = text
    end
  end
  if type(value) ~= "table" then
    add(tostring(value))
    return out
  end
  add(value.label)
  add(value.display_name)
  add(value.username)
  add(value.real_name)
  local ref = value.user_reference
  if type(ref) == "table" then
    add(ref.real_name)
    add(ref.display_name)
    add(ref.username)
  end
  if value.id ~= nil then
    add(tostring(value.id))
  end
  return out
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
    by_id[value.id] = M.value_display(value)
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
    or item.ref -- cross reference fields carry `{ref = "art #12", url = ...}`
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
    -- `cross` fields carry a list of references under `value`.
    if vim.islist(value.value) and #value.value > 0 then
      local labels = {}
      for _, item in ipairs(value.value) do
        labels[#labels + 1] = item_label(item)
      end
      if #labels > 0 then
        return table.concat(labels, ", ")
      end
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
