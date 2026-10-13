---@mod tuleap.util.date ISO-8601 helpers
---
--- Tuleap sends dates as `2026-01-05T00:00:00+01:00`. Charts need them as
--- comparable numbers, views need them short and readable.

local M = {}

M.DAY = 86400

--- Parse an ISO-8601 timestamp into a Unix time.
---@param value string|number|nil
---@return integer? timestamp
function M.parse(value)
  if type(value) == "number" then
    return value
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local year, month, day = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not year then
    return nil
  end
  local hour, min, sec = value:match("T(%d%d):(%d%d):(%d%d)")
  local stamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour) or 12,
    min = tonumber(min) or 0,
    sec = tonumber(sec) or 0,
    isdst = false,
  })
  -- Normalise to the date's local noon so day arithmetic never trips on DST.
  return stamp
end

---@param timestamp integer?
---@param fmt string?
---@return string
function M.format(timestamp, fmt)
  if not timestamp then
    return "—"
  end
  return os.date(fmt or "%Y-%m-%d", timestamp) --[[@as string]]
end

---@param value string|number|nil
---@param fmt string?
---@return string
function M.pretty(value, fmt)
  return M.format(M.parse(value), fmt)
end

--- Whole days between two timestamps (b - a).
---@param a integer
---@param b integer
---@return integer
function M.days_between(a, b)
  return math.floor((b - a) / M.DAY + 0.5)
end

--- Midnight of the day holding `timestamp`.
---@param timestamp integer
---@return integer
function M.start_of_day(timestamp)
  local parts = os.date("*t", timestamp) --[[@as table]]
  parts.hour, parts.min, parts.sec = 0, 0, 0
  return os.time(parts)
end

--- "3 days ago", "in 2 weeks", ...
---@param value string|number|nil
---@return string
function M.relative(value)
  local timestamp = M.parse(value)
  if not timestamp then
    return "—"
  end
  local delta = os.time() - timestamp
  local future = delta < 0
  delta = math.abs(delta)
  local units = {
    { 31536000, "year" },
    { 2592000, "month" },
    { 604800, "week" },
    { 86400, "day" },
    { 3600, "hour" },
    { 60, "minute" },
  }
  for _, unit in ipairs(units) do
    if delta >= unit[1] then
      local count = math.floor(delta / unit[1])
      local label = ("%d %s%s"):format(count, unit[2], count > 1 and "s" or "")
      return future and ("in " .. label) or (label .. " ago")
    end
  end
  return "just now"
end

return M
