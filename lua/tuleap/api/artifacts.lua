---@mod tuleap.api.artifacts Artifact CRUD
---
--- Artifacts back every item type: issues, epics, user stories and the
--- artifacts behind milestones. Closing an artifact means setting its status
--- semantic to a value outside the tracker's `open_values`.

local client = require("tuleap.api.client")
local cache = require("tuleap.cache")
local trackers = require("tuleap.api.trackers")

local M = {}

--- Drop every cached artifact/tracker listing after a write.
local function invalidate()
  cache.invalidate("GET:" .. (require("tuleap.config").url() or ""))
end

---@param id integer
---@param cb fun(err: string?, artifact: table?)
---@param opts {refresh: boolean?}?
function M.get(id, cb, opts)
  client.get(("/artifacts/%d"):format(id), nil, cb, {
    cache_ttl = (opts and opts.refresh) and 0 or 30,
  })
end

---@class tuleap.ListOpts
---@field expert_query string? Tuleap TQL, e.g. `status = "Open" AND assigned_to = MYSELF()`
---@field limit integer?
---@field max_pages integer?
---@field values "all"|"summary"|nil

--- List artifacts of a tracker.
---@param tracker_id integer
---@param opts tuleap.ListOpts?
---@param cb fun(err: string?, artifacts: table[]?)
function M.list(tracker_id, opts, cb)
  opts = opts or {}
  local query = { values = opts.values or "all" }
  if opts.expert_query and opts.expert_query ~= "" then
    query.expert_query = opts.expert_query
  end
  client.paginate(("/trackers/%d/artifacts"):format(tracker_id), query, function(err, items)
    if err and opts.expert_query then
      err = ("%s\nTQL used: %s"):format(err, opts.expert_query)
    end
    cb(err, items)
  end, { limit = opts.limit, max_pages = opts.max_pages, cache_ttl = 30 })
end

--- Create an artifact.
---@param tracker_id integer
---@param values table[] already built by |tuleap.api.trackers.value_payload|
---@param cb fun(err: string?, artifact: table?)
function M.create(tracker_id, values, cb)
  client.post("/artifacts", { tracker = { id = tracker_id }, values = values }, function(err, data)
    if not err then
      invalidate()
    end
    cb(err, data)
  end)
end

--- Update an artifact, optionally attaching a follow-up comment.
---@param id integer
---@param values table[]
---@param comment string?
---@param cb fun(err: string?)
function M.update(id, values, comment, cb)
  local body = { values = values or {} }
  if comment and comment ~= "" then
    body.comment = { body = comment, format = "text" }
  end
  client.put(("/artifacts/%d"):format(id), body, function(err)
    if not err then
      invalidate()
    end
    cb(err)
  end)
end

--- Post a comment without touching any field.
---@param id integer
---@param comment string
---@param cb fun(err: string?)
function M.comment(id, comment, cb)
  M.update(id, {}, comment, cb)
end

--- Permanently delete an artifact.
---
--- Tuleap restricts this to site administrators and applies a strict quota
--- (a handful of deletions per project per day), so expect HTTP 403/429 on a
--- regular account.
---@param id integer
---@param cb fun(err: string?)
function M.delete(id, cb)
  client.delete(("/artifacts/%d"):format(id), function(err)
    if not err then
      invalidate()
    end
    cb(err)
  end)
end

--- Move an artifact to a closed status.
---@param id integer
---@param opts {status_id: integer?, comment: string?}
---@param cb fun(err: string?, chosen: table?)
function M.close(id, opts, cb)
  opts = opts or {}
  M.get(id, function(err, artifact)
    if err then
      return cb(err)
    end
    local tracker_id = artifact and artifact.tracker and artifact.tracker.id
    if not tracker_id then
      return cb("artifact has no tracker")
    end
    trackers.get(tracker_id, function(terr, tracker)
      if terr then
        return cb(terr)
      end
      local closed, field, unknown = trackers.closed_values(tracker)
      if not field then
        return cb("this tracker has no status semantic, cannot close from here")
      end
      if #closed == 0 then
        return cb("the status field exposes no closed value")
      end
      -- Without a published open/closed split, only an explicit status is safe.
      if unknown and not opts.status_id then
        return cb(
          "this tracker does not publish which statuses are open — pass an explicit status"
        )
      end

      local chosen
      if opts.status_id then
        for _, value in ipairs(closed) do
          if value.id == opts.status_id then
            chosen = value
          end
        end
      end
      chosen = chosen or closed[1]

      local payload = trackers.value_payload(field, chosen.id)
      M.update(id, { payload }, opts.comment, function(uerr)
        cb(uerr, chosen)
      end)
    end)
  end, { refresh = true })
end

--- Follow-up comments, newest last.
---@param id integer
---@param cb fun(err: string?, changesets: table[]?)
function M.changesets(id, cb)
  client.paginate(("/artifacts/%d/changesets"):format(id), { fields = "comments" }, cb, {
    cache_ttl = 15,
  })
end

--- Artifacts linked to this one.
---
--- The links are read from the artifact's own artifact-link field rather than
--- from `/artifacts/{id}/linked_artifacts`: that route answers an empty
--- collection on some Tuleap versions even for artifacts that demonstrably
--- have children. The field value is also richer — it carries the link nature
--- and both directions. The route is still used as a fallback when the field
--- is not exposed.
---@param id integer
---@param direction "forward"|"reverse"
---@param cb fun(err: string?, artifacts: table[]?)
---@param opts {resolve: boolean?, limit: integer?}? resolve fetches each linked artifact for its title
function M.links(id, direction, cb, opts)
  opts = opts or {}
  direction = direction or "forward"
  local limit = opts.limit or 50

  --- Fetch each linked artifact so callers get titles, not just ids.
  ---@param raw table[]
  local function resolve(raw)
    if opts.resolve == false or #raw == 0 then
      return cb(nil, raw)
    end
    local out, pending = {}, 0
    for index, link in ipairs(raw) do
      if index <= limit then
        out[index] = link
        pending = pending + 1
      end
    end
    if pending == 0 then
      return cb(nil, {})
    end
    for index, link in ipairs(out) do
      M.get(link.id, function(err, full)
        if not err and full then
          out[index] = vim.tbl_extend("keep", { type = link.type }, full)
        end
        pending = pending - 1
        if pending == 0 then
          cb(nil, out)
        end
      end)
    end
  end

  M.get(id, function(err, artifact)
    if err then
      return cb(err)
    end
    for _, value in ipairs((artifact or {}).values or {}) do
      if value.type == "art_link" then
        local raw = direction == "reverse" and value.reverse_links or value.links
        return resolve(raw or {})
      end
    end
    -- No artifact-link field exposed: ask the dedicated route instead, through
    -- `paginate` so it picks up that route's own `limit` cap.
    client.paginate(("/artifacts/%d/linked_artifacts"):format(id), {
      direction = direction,
    }, function(lerr, collection)
      if lerr then
        return cb(lerr)
      end
      cb(nil, collection or {})
    end, { cache_ttl = 30 })
  end)
end

--- The tracker's artifact link field, if it has one.
---@param tracker table
---@return table?
function M.link_field(tracker)
  for _, field in ipairs((tracker or {}).fields or {}) do
    if field.type == "art_link" then
      return field
    end
  end
  return nil
end

--- Link `child_id` under `parent_id`.
---
--- Tuleap's artifact link field is written as a *whole list*: a PUT replaces
--- every existing link. The current links are therefore read back first and
--- the write is aborted if they cannot be read, so an unreadable field can
--- never silently wipe an artifact's hierarchy.
---
--- The parent holds a forward link of nature `_is_child` to each of its
--- children, which is what `linked_artifacts?direction=forward` returns.
---@param parent_id integer artifact that becomes the parent (e.g. the epic)
---@param child_id integer artifact that becomes the child (e.g. the issue)
---@param opts {nature: string?, comment: string?}?
---@param cb fun(err: string?, result: {added: boolean?, already: boolean?}?)
function M.add_link(parent_id, child_id, opts, cb)
  opts = opts or {}
  local nature = opts.nature or require("tuleap.config").options.links.parent_nature

  M.get(parent_id, function(err, parent)
    if err then
      return cb(err)
    end
    local tracker_id = parent.tracker and parent.tracker.id
    if not tracker_id then
      return cb(("artifact #%d has no tracker"):format(parent_id))
    end
    trackers.get(tracker_id, function(terr, tracker)
      if terr then
        return cb(terr)
      end
      local field = M.link_field(tracker)
      if not field then
        return cb(
          ("tracker %s has no artifact link field, so #%d cannot hold children"):format(
            tracker.label or tracker_id,
            parent_id
          )
        )
      end

      local existing, present = {}, false
      for _, value in ipairs(parent.values or {}) do
        if value.field_id == field.field_id then
          present = true
          for _, link in ipairs(value.links or {}) do
            existing[#existing + 1] = { id = link.id, type = link.type or link.nature }
          end
        end
      end

      --- Append the child and write the whole list back.
      ---@param current {id: integer, type: string?}[]
      local function write(current)
        for _, link in ipairs(current) do
          if tostring(link.id) == tostring(child_id) then
            return cb(nil, { already = true })
          end
        end
        current[#current + 1] = { id = tonumber(child_id), type = nature }
        M.update(parent_id, { { field_id = field.field_id, links = current } }, opts.comment, function(uerr)
          cb(uerr, { added = true })
        end)
      end

      if present then
        return write(existing)
      end

      -- Tuleap leaves the artifact link field out of `values` entirely when an
      -- artifact has no links yet. That is indistinguishable from "could not
      -- read it", so confirm against the dedicated endpoint before writing: an
      -- empty collection means there is genuinely nothing to preserve.
      M.links(parent_id, "forward", function(lerr, current)
        if lerr then
          return cb(
            ("could not read the current links of #%d (%s) — refusing to replace them"):format(
              parent_id,
              lerr
            )
          )
        end
        if #(current or {}) > 0 then
          return cb(
            ("#%d has %d links that the artifact payload did not expose — refusing to replace them"):format(
              parent_id,
              #current
            )
          )
        end
        write({})
      end, { resolve = false })
    end)
  end, { refresh = true })
end

--- Title of an artifact, whatever the tracker calls its title field.
---@param artifact table
---@return string
function M.title(artifact)
  if type(artifact) ~= "table" then
    return ""
  end
  if artifact.title and artifact.title ~= "" then
    return artifact.title
  end
  if artifact.label and artifact.label ~= "" then
    return artifact.label
  end
  for _, value in ipairs(artifact.values or {}) do
    if value.label == "Summary" or value.field_id and value.type == "string" then
      local rendered = trackers.render_value(value)
      if rendered ~= "" then
        return rendered
      end
    end
  end
  return ("artifact #%s"):format(tostring(artifact.id))
end

--- Cross reference such as "bug #1234".
---@param artifact table
---@return string
function M.xref(artifact)
  return artifact.xref or ("#" .. tostring(artifact.id))
end

---@param artifact table
---@return string
function M.status(artifact)
  if type(artifact.full_status) == "table" and artifact.full_status.value then
    return tostring(artifact.full_status.value)
  end
  return artifact.status or ""
end

--- Whether the artifact sits in an open status. Tuleap exposes `is_open` on
--- recent versions; otherwise fall back to the status string.
---@param artifact table
---@return boolean
function M.is_open(artifact)
  if type(artifact.is_open) == "boolean" then
    return artifact.is_open
  end
  local status = M.status(artifact):lower()
  if status == "" then
    return true
  end
  for _, closed in ipairs({ "closed", "done", "fixed", "resolved", "cancel", "declined", "rejected", "delivered" }) do
    if status:find(closed, 1, true) then
      return false
    end
  end
  return true
end

--- Browser URL of an artifact.
---@param artifact table|integer
---@return string
function M.url(artifact)
  local config = require("tuleap.config")
  local base = config.url() or ""
  if type(artifact) == "table" then
    if artifact.html_url and artifact.html_url ~= "" then
      local href = artifact.html_url
      return href:match("^https?://") and href or (base .. href)
    end
    artifact = artifact.id
  end
  return ("%s/plugins/tracker/?aid=%s"):format(base, tostring(artifact))
end

--- Numeric value of a field, used by the burnup fallback.
---@param artifact table
---@param field_names string[]
---@return number?
function M.numeric_field(artifact, field_names)
  for _, value in ipairs(artifact.values or {}) do
    for _, name in ipairs(field_names) do
      if value.field_id and ((value.label or ""):lower():find(name) or (value.name or "") == name) then
        local number = tonumber(value.value) or tonumber(value.manual_value)
        if number then
          return number
        end
      end
    end
  end
  return nil
end

return M
