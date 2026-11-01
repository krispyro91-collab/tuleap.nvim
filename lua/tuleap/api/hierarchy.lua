---@mod tuleap.api.hierarchy The epic and sprint an artifact belongs to
---
--- Both are recorded on the artifact as *reverse links*: the epic holds the
--- artifact as a child, and the sprint holds it as content. Trackers without an
--- artifact link field only show them as incoming cross references, such as
--- "sprint #1" in their "References" field. Either way a reverse link only
--- carries an id (and on some versions a tracker), never a name, so the names
--- are looked up here for a whole list at once:
---
---   - sprints from the project's milestone listing, which the sprint picker
---     already caches — a milestone's id is the id of its artifact;
---   - epics by reading each distinct parent once, a few at a time. Artifacts
---     of a list share a handful of epics, so this stays small.

local artifacts = require("tuleap.api.artifacts")
local milestones = require("tuleap.api.milestones")
local projects = require("tuleap.api.projects")
local trackers = require("tuleap.api.trackers")

local M = {}

---@class tuleap.Parents
---@field epic table? the epic artifact
---@field sprint table? the milestone, carrying `label`, `start_date` and `end_date`

--- Cross references of an artifact, from its "References" fields: `ref` is
--- the reference as typed ("bug #12"), `key` its keyword and `id` the artifact.
---@param artifact table
---@return {id: integer, key: string, ref: string, direction: string?}[]
function M.references(artifact)
  local out = {}
  for _, value in ipairs((artifact or {}).values or {}) do
    if value.type == "cross" and type(value.value) == "table" then
      for _, item in ipairs(value.value) do
        local key, id = tostring(item.ref or ""):match("^(%S+)%s+#(%d+)$")
        if id then
          out[#out + 1] =
            { id = tonumber(id), key = key, ref = item.ref, direction = item.direction }
        end
      end
    end
  end
  return out
end

--- Reverse links of an artifact: those of its artifact link field, then the
--- incoming cross references. Trackers without a link field still record
--- their epic and sprint the second way.
---@param artifact table
---@return table[] links carrying `id`, and `tracker` or `key` when known
function M.reverse_links(artifact)
  local out, seen = {}, {}
  for _, value in ipairs((artifact or {}).values or {}) do
    if value.type == "art_link" then
      for _, link in ipairs(value.reverse_links or {}) do
        local id = tonumber(link.id)
        if id and not seen[id] then
          seen[id] = true
          out[#out + 1] = link
        end
      end
    end
  end
  for _, ref in ipairs(M.references(artifact)) do
    if ref.direction ~= "out" and not seen[ref.id] then
      seen[ref.id] = true
      out[#out + 1] = { id = ref.id, key = ref.key }
    end
  end
  return out
end

---@param cb fun(tracker_id: integer?, item_name: string?)
local function epic_tracker(cb)
  trackers.resolve("epic", function(err, tracker_id)
    local id = not err and tonumber(tracker_id) or nil
    if not id then
      return cb(nil)
    end
    trackers.get(id, function(_, tracker)
      cb(id, tracker and tracker.item_name)
    end)
  end)
end

--- Keyword of an artifact's own references: "bug" for "bug #12".
---@param artifact table
---@return string?
local function own_key(artifact)
  return artifact.xref and tostring(artifact.xref):match("^(%S+)%s+#%d+$")
end

---@param cb fun(by_id: table<integer, table>)
local function all_milestones(cb)
  projects.current(function(err, project_id)
    if err or not project_id then
      return cb({})
    end
    milestones.all(project_id, function(merr, list)
      local by_id = {}
      for _, milestone in ipairs(not merr and list or {}) do
        for _, id in ipairs({ milestone.id, milestone.artifact and milestone.artifact.id }) do
          if tonumber(id) then
            by_id[tonumber(id)] = milestone
          end
        end
      end
      cb(by_id)
    end)
  end)
end

--- The epic and sprint of every artifact in `list`, by artifact id. An artifact
--- with neither — or whose payload exposes no reverse links — has no entry.
---@param list table[]
---@param cb fun(parents: table<integer, tuleap.Parents>)
function M.resolve(list, cb)
  local epic_id, epic_key, sprints
  local pending = 2

  --- Whether a reverse link may be an epic, before reading it.
  ---@param link table
  ---@param artifact table the artifact it was found on
  local function may_be_epic(link, artifact)
    local tracker = link.tracker and tonumber(link.tracker.id)
    if tracker then
      return tracker == epic_id
    end
    if link.key then
      if epic_key then
        return link.key == epic_key
      end
      -- An epic is never on the artifact's own tracker.
      return link.key ~= own_key(artifact)
    end
    return true
  end

  local function classify()
    -- Reverse links that may be epics: not a milestone, and not on another
    -- tracker when the link tells which one it is on.
    local wanted, todo = {}, {}
    for _, artifact in ipairs(list or {}) do
      for _, link in ipairs(M.reverse_links(artifact)) do
        local id = tonumber(link.id)
        if
          epic_id
          and id
          and not sprints[id]
          and not wanted[id]
          and may_be_epic(link, artifact)
        then
          wanted[id] = true
          todo[#todo + 1] = { id = id }
        end
      end
    end

    artifacts.expand(todo, function(fetched)
      local epics = {}
      for _, parent in ipairs(fetched) do
        if parent.tracker and tonumber(parent.tracker.id) == epic_id then
          epics[tonumber(parent.id)] = parent
        end
      end

      local out = {}
      for _, artifact in ipairs(list or {}) do
        local found = {}
        for _, link in ipairs(M.reverse_links(artifact)) do
          local id = tonumber(link.id)
          if id and epics[id] and not found.epic then
            found.epic = epics[id]
          end
          local milestone = id and sprints[id]
          -- A sprint wins over the release above it.
          if
            milestone
            and (not found.sprint or (milestone.__depth or 0) > (found.sprint.__depth or 0))
          then
            found.sprint = milestone
          end
        end
        if (found.epic or found.sprint) and artifact.id then
          out[tonumber(artifact.id) or artifact.id] = found
        end
      end
      cb(out)
    end)
  end

  local function done()
    pending = pending - 1
    if pending == 0 then
      classify()
    end
  end

  epic_tracker(function(id, item_name)
    epic_id, epic_key = id, item_name
    done()
  end)
  all_milestones(function(by_id)
    sprints = by_id
    done()
  end)
end

return M
