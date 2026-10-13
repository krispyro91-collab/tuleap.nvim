---@mod tuleap.api.milestones Milestones, burndown and burnup
---
--- Tuleap's Agile Dashboard exposes releases and sprints as *milestones*.
--- Burndown data comes straight from `/milestones/{id}/burndown`. Burnup is
--- only exposed by recent Tuleap versions; when the route is missing the
--- series is derived from the burndown so the chart still renders — see
--- |tuleap.api.milestones.burnup|.

local client = require("tuleap.api.client")
local date = require("tuleap.util.date")

local M = {}

--- Top level milestones (usually releases) of a project.
---@param project_id integer
---@param opts {status: "open"|"closed"|"all"|nil}?
---@param cb fun(err: string?, milestones: table[]?)
function M.list(project_id, opts, cb)
  opts = opts or {}
  local query = {}
  if opts.status and opts.status ~= "all" then
    query.query = { status = opts.status }
  end
  client.paginate(("/projects/%d/milestones"):format(project_id), query, function(err, items)
    if err and query.query then
      -- `query` filtering is rejected by some versions: retry without it.
      return client.paginate(("/projects/%d/milestones"):format(project_id), nil, cb, { cache_ttl = 60 })
    end
    cb(err, items)
  end, { cache_ttl = 60 })
end

--- Sub-milestones, i.e. the sprints of a release.
---@param milestone_id integer
---@param cb fun(err: string?, milestones: table[]?)
function M.children(milestone_id, cb)
  client.paginate(("/milestones/%d/milestones"):format(milestone_id), nil, cb, { cache_ttl = 60 })
end

---@param milestone_id integer
---@param cb fun(err: string?, milestone: table?)
function M.get(milestone_id, cb)
  client.get(("/milestones/%d"):format(milestone_id), nil, cb, { cache_ttl = 60 })
end

--- Artifacts planned in the milestone.
---@param milestone_id integer
---@param cb fun(err: string?, artifacts: table[]?)
function M.content(milestone_id, cb)
  client.paginate(("/milestones/%d/content"):format(milestone_id), nil, cb, { cache_ttl = 30 })
end

--- Add artifacts to a milestone's content (i.e. plan them in the sprint).
---
--- Prefers `PATCH .../content {add: [...]}`, which is incremental. Instances
--- that do not implement PATCH on that route fall back to re-sending the full
--- id list with PUT — and that fallback is only attempted when the current
--- content could be read, so it cannot truncate the sprint.
---@param milestone_id integer
---@param artifact_ids integer[]
---@param cb fun(err: string?)
function M.add_content(milestone_id, artifact_ids, cb)
  local path = ("/milestones/%d/content"):format(milestone_id)
  local add = {}
  for _, id in ipairs(artifact_ids) do
    add[#add + 1] = { id = tonumber(id) }
  end
  if #add == 0 then
    return cb(nil)
  end

  client.patch(path, { add = add }, function(patch_err)
    if not patch_err then
      return cb(nil)
    end
    M.content(milestone_id, function(read_err, current)
      if read_err then
        return cb(patch_err)
      end
      local ids, seen = {}, {}
      for _, artifact in ipairs(current or {}) do
        if artifact.id and not seen[artifact.id] then
          seen[artifact.id] = true
          ids[#ids + 1] = artifact.id
        end
      end
      for _, id in ipairs(artifact_ids) do
        local numeric = tonumber(id)
        if numeric and not seen[numeric] then
          seen[numeric] = true
          ids[#ids + 1] = numeric
        end
      end
      client.put(path, { ids = ids }, function(put_err)
        cb(put_err and ("PATCH failed (%s); PUT failed (%s)"):format(patch_err, put_err) or nil)
      end)
    end)
  end)
end

--- Artifacts in the milestone backlog (planned but not in a child sprint).
---@param milestone_id integer
---@param cb fun(err: string?, artifacts: table[]?)
function M.backlog(milestone_id, cb)
  client.paginate(("/milestones/%d/backlog"):format(milestone_id), nil, cb, { cache_ttl = 30 })
end

--- Every sprint of a project: the top milestones plus their children.
---@param project_id integer
---@param cb fun(err: string?, milestones: table[]?)
function M.all(project_id, cb)
  M.list(project_id, { status = "all" }, function(err, tops)
    if err then
      return cb(err)
    end
    tops = tops or {}
    if #tops == 0 then
      return cb(nil, {})
    end
    local out = {}
    local pending = #tops
    for index, top in ipairs(tops) do
      top.__depth = 0
      out[#out + 1] = { order = index * 1000, item = top }
      M.children(top.id, function(cerr, kids)
        if not cerr then
          for kid_index, kid in ipairs(kids or {}) do
            kid.__depth = 1
            kid.__parent = top.label
            out[#out + 1] = { order = index * 1000 + kid_index, item = kid }
          end
        end
        pending = pending - 1
        if pending == 0 then
          table.sort(out, function(a, b)
            return a.order < b.order
          end)
          local flat = {}
          for _, entry in ipairs(out) do
            flat[#flat + 1] = entry.item
          end
          cb(nil, flat)
        end
      end)
    end
  end)
end

---@class tuleap.Series
---@field name string
---@field points {x: number, y: number}[]

---@class tuleap.ChartData
---@field start_date integer?
---@field end_date integer?
---@field duration integer?
---@field capacity number?
---@field series tuleap.Series[]
---@field derived boolean? true when the burnup was computed locally
---@field unit string?

--- Normalise the `/burndown` payload into plot-ready series.
---
--- The ideal line is deliberately anchored on the *milestone* period rather
--- than on the burndown's own `duration`: Tuleap counts duration in working
--- days on many configurations, so `start + duration` lands short of the real
--- end date and the guideline stops before the deadline.
---@param raw table
---@param period {start: integer?, finish: integer?}? milestone period, when known
---@return tuleap.ChartData
local function normalise_burndown(raw, period)
  period = period or {}
  local start = date.parse(raw.start_date)
  local points = {}

  if type(raw.points_with_date) == "table" and #raw.points_with_date > 0 then
    for _, point in ipairs(raw.points_with_date) do
      local stamp = date.parse(point.date)
      if stamp then
        points[#points + 1] = {
          x = stamp,
          y = tonumber(point.remaining_effort) or tonumber(point.value) or 0,
        }
      end
    end
  elseif type(raw.points) == "table" then
    for index, value in ipairs(raw.points) do
      if value ~= vim.NIL then
        points[#points + 1] = {
          x = (start or os.time()) + (index - 1) * date.DAY,
          y = tonumber(value) or 0,
        }
      end
    end
  end

  table.sort(points, function(a, b)
    return a.x < b.x
  end)

  local duration = tonumber(raw.duration)

  -- Where the guideline starts and ends, most trustworthy source first.
  local ideal_start = period.start or start or (points[1] and points[1].x)
  local ideal_end = period.finish
    or (start and duration and (start + duration * date.DAY))
    or (points[#points] and points[#points].x)

  local capacity = tonumber(raw.capacity)
  if not capacity or capacity == 0 then
    capacity = points[1] and points[1].y or 0
  end

  -- A burndown guideline starts at the scope actually recorded on day one;
  -- `capacity` is the team's capacity, which is a different number.
  local initial = capacity
  if points[1] and points[1].y and points[1].y > 0 then
    initial = points[1].y
  end

  local series = { { name = "Remaining", points = points } }

  if ideal_start and ideal_end and initial > 0 and ideal_end > ideal_start then
    series[#series + 1] = {
      name = "Ideal",
      style = "dashed",
      points = { { x = ideal_start, y = initial }, { x = ideal_end, y = 0 } },
    }
  end

  return {
    start_date = ideal_start,
    end_date = ideal_end,
    duration = duration,
    capacity = capacity,
    initial = initial,
    series = series,
    is_under_calculation = raw.is_under_calculation,
  }
end

--- Burndown chart data for a milestone.
---@param milestone_id integer
---@param cb fun(err: string?, data: tuleap.ChartData?)
---@param opts {period: {start: integer?, finish: integer?}?}?
function M.burndown(milestone_id, cb, opts)
  client.get(("/milestones/%d/burndown"):format(milestone_id), nil, function(err, raw)
    if err then
      return cb(err)
    end
    if type(raw) ~= "table" then
      return cb("the burndown endpoint returned no data for this milestone")
    end
    local data = normalise_burndown(raw, (opts or {}).period)
    if #(data.series[1].points or {}) == 0 then
      return cb(
        "no burndown points yet — the tracker needs a burndown field and a remaining effort"
      )
    end
    cb(nil, data)
  end, { cache_ttl = 60 })
end

--- Normalise the native `/burnup` payload.
---@param raw table
---@return tuleap.ChartData?
local function normalise_burnup(raw)
  local entries = raw.points_with_date or raw.points
  if type(entries) ~= "table" or #entries == 0 then
    return nil
  end
  local done, scope = {}, {}
  for index, point in ipairs(entries) do
    local stamp = date.parse(point.date) or ((date.parse(raw.start_date) or os.time()) + (index - 1) * date.DAY)
    local team = tonumber(point.team_effort) or tonumber(point.done) or tonumber(point.value)
    local total = tonumber(point.total_effort) or tonumber(point.total)
    if team then
      done[#done + 1] = { x = stamp, y = team }
    end
    if total then
      scope[#scope + 1] = { x = stamp, y = total }
    end
  end
  if #done == 0 then
    return nil
  end
  return {
    start_date = date.parse(raw.start_date),
    duration = tonumber(raw.duration),
    capacity = tonumber(raw.capacity),
    series = {
      { name = "Completed", points = done },
      { name = "Scope", points = scope },
    },
  }
end

--- Burnup chart data for a milestone.
---
--- Tries the native `/milestones/{id}/burnup` route first. Instances that do
--- not expose it get a locally derived burnup: the scope line is the sprint
--- capacity and the completed line is `capacity - remaining` from the
--- burndown. The returned table then carries `derived = true`, and the chart
--- view labels itself accordingly.
---@param milestone_id integer
---@param cb fun(err: string?, data: tuleap.ChartData?)
---@param opts {period: {start: integer?, finish: integer?}?}?
function M.burnup(milestone_id, cb, opts)
  client.get(("/milestones/%d/burnup"):format(milestone_id), nil, function(err, raw)
    if not err and type(raw) == "table" then
      local data = normalise_burnup(raw)
      if data then
        return cb(nil, data)
      end
    end

    M.burndown(milestone_id, function(berr, burndown)
      if berr then
        return cb(berr)
      end
      local remaining = burndown.series[1].points
      local capacity = burndown.capacity or 0
      for _, point in ipairs(remaining) do
        capacity = math.max(capacity, point.y)
      end

      local done = {}
      for _, point in ipairs(remaining) do
        done[#done + 1] = { x = point.x, y = math.max(0, capacity - point.y) }
      end
      -- The scope is flat by construction, so draw it across the whole sprint
      -- rather than stopping where the burndown samples stop.
      local scope = {
        { x = burndown.start_date or done[1].x, y = capacity },
        { x = burndown.end_date or done[#done].x, y = capacity },
      }

      cb(nil, {
        start_date = burndown.start_date,
        end_date = burndown.end_date,
        duration = burndown.duration,
        capacity = capacity,
        derived = true,
        series = {
          { name = "Completed", points = done },
          { name = "Scope", style = "dashed", points = scope },
        },
      })
    end, opts)
  end, { cache_ttl = 60 })
end

--- Label of a milestone, indented for sub-milestones.
---@param milestone table
---@return string
function M.label(milestone)
  local prefix = (milestone.__depth or 0) > 0 and "  ↳ " or ""
  return prefix .. (milestone.label or milestone.title or ("milestone #" .. tostring(milestone.id)))
end

---@param milestone table
---@return string
function M.url(milestone)
  local config = require("tuleap.config")
  local base = config.url() or ""
  local href = milestone.html_url or milestone.uri
  if href and href:match("^https?://") then
    return href
  end
  if href then
    return base .. (href:sub(1, 1) == "/" and href or ("/" .. href))
  end
  return ("%s/plugins/agiledashboard/?action=show&aid=%s"):format(base, tostring(milestone.id))
end

return M
