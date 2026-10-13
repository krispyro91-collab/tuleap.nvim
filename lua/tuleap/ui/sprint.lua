---@mod tuleap.ui.sprint Sprint dashboard with burndown and burnup
---
--- Renders a milestone summary followed by its burndown and burnup charts.
--- Press `t` to cycle between both charts, burndown only and burnup only when
--- the window is too short to show everything comfortably.

local artifacts = require("tuleap.api.artifacts")
local chart = require("tuleap.ui.chart")
local config = require("tuleap.config")
local date = require("tuleap.util.date")
local milestones = require("tuleap.api.milestones")
local render = require("tuleap.ui.render")
local window = require("tuleap.ui.window")

local M = {}

local MODES = { "both", "burndown", "burnup" }

---@param milestone table
---@return integer? start_ts, integer? end_ts
local function period(milestone)
  local start = date.parse(milestone.start_date)
  local finish = date.parse(milestone.end_date)
  if not finish and start and milestone.duration then
    finish = start + tonumber(milestone.duration) * date.DAY
  end
  return start, finish
end

---@param state table
---@param width integer
---@return tuleap.Builder
local function header(state, width)
  local milestone = state.milestone
  local icons = config.options.ui.icons
  local builder = render.builder(width)

  builder:line({
    { "  " .. icons.sprint .. "  ", "TuleapOpen" },
    { milestone.label or ("milestone #" .. tostring(milestone.id)), "TuleapTitle" },
    { milestone.semantic_status and ("   " .. milestone.semantic_status) or "", "TuleapLabel" },
  })
  builder:rule("─", width)

  local start, finish = period(milestone)
  local period_text = "—"
  if start and finish then
    local total = date.days_between(start, finish)
    local left = date.days_between(os.time(), finish)
    period_text = ("%s → %s  (%d days, %s)"):format(
      date.format(start),
      date.format(finish),
      total,
      left >= 0 and (left .. " left") or ("ended " .. -left .. " days ago")
    )
  end
  builder:field("Period", period_text, { hl = "TuleapDate" })

  local capacity = tonumber(milestone.capacity)
  local remaining = tonumber(milestone.remaining_effort)
  local initial = tonumber(milestone.initial_effort)
  local stats = {}
  if capacity then
    stats[#stats + 1] = ("capacity %s"):format(capacity)
  end
  if initial then
    stats[#stats + 1] = ("planned %s"):format(initial)
  end
  if remaining then
    stats[#stats + 1] = ("remaining %s"):format(remaining)
  end
  if #stats > 0 then
    builder:field("Effort", table.concat(stats, "  ·  "))
  end

  -- Progress comes from the effort when available, otherwise from item counts.
  local ratio
  if initial and initial > 0 and remaining then
    ratio = math.max(0, math.min(1, (initial - remaining) / initial))
  elseif state.content then
    local closed = 0
    for _, artifact in ipairs(state.content) do
      if not artifacts.is_open(artifact) then
        closed = closed + 1
      end
    end
    ratio = #state.content > 0 and closed / #state.content or nil
  end
  if ratio then
    local bar, filled = chart.progress_bar(ratio, math.min(30, width - 24))
    local row = builder:field("Progress", bar)
    local offset = #("  Progress" .. (" "):rep(math.max(1, 14 - #"Progress")))
    builder.highlights[#builder.highlights + 1] =
      { row = row, col = offset, end_col = offset + filled, hl = "TuleapProgressFilled" }
  end

  if state.content then
    local open = 0
    for _, artifact in ipairs(state.content) do
      if artifacts.is_open(artifact) then
        open = open + 1
      end
    end
    builder:field(
      "Content",
      ("%d artifacts  ·  %d open  ·  %d closed"):format(
        #state.content,
        open,
        #state.content - open
      )
    )
  end

  return builder
end

---@param data tuleap.ChartData
---@param title string
---@param width integer
---@param height integer
---@param domain {min: integer?, max: integer?}?
---@return table output
local function plot(data, title, width, height, domain)
  local markers = {}
  if config.options.chart.show_today then
    local now = os.time()
    if data.start_date and now >= data.start_date then
      markers[#markers + 1] = { x = now, label = "today" }
    end
  end

  local series = {}
  for _, item in ipairs(data.series) do
    if #(item.points or {}) > 0 then
      if item.name ~= "Ideal" or config.options.chart.show_ideal then
        series[#series + 1] = item
      end
    end
  end

  return chart.render({
    title = title,
    series = series,
    width = width,
    height = height,
    markers = markers,
    x_min = domain and domain.min,
    x_max = domain and domain.max,
    x_format = function(x)
      return date.format(x, "%d/%m")
    end,
    y_format = function(y)
      if math.abs(y - math.floor(y + 0.5)) < 1e-6 then
        return tostring(math.floor(y + 0.5))
      end
      return ("%.1f"):format(y)
    end,
  })
end

--- Open the sprint dashboard.
---@param milestone_id integer
---@param opts {mode: string?}?
function M.open(milestone_id, opts)
  opts = opts or {}
  local keys = config.options.keymaps.chart
  local win = window.open({
    title = ("Tuleap sprint #%d"):format(milestone_id),
    filetype = "tuleap-sprint",
    footer = config.options.ui.show_help_hint
        and ("%s toggle charts  %s content  %s refresh  %s browser  %s close"):format(
          keys.toggle or "-",
          keys.content or "-",
          keys.refresh or "-",
          keys.open_browser or "-",
          keys.close or "-"
        )
      or nil,
  })
  win:loading(("Loading sprint #%d …"):format(milestone_id))

  local state = { mode = opts.mode or "both" }

  local function draw()
    if not win:valid() or not state.milestone then
      return
    end
    local width = win.width - 2
    local builder = header(state, width)

    local overhead = 5 -- title + axis + ticks + legend + blank
    local available = win.height - #builder.lines - 2
    local configured = config.options.chart.height
    local height

    if state.mode == "both" then
      height = math.floor((available - 2 * overhead) / 2)
    else
      height = available - overhead
    end
    height = math.max(7, math.min(configured, height))

    local chart_width = config.options.chart.width or width

    -- Both charts share the sprint period so they can be read side by side.
    local start, finish = period(state.milestone)
    local domain = { min = start, max = finish }

    local function section(title, data, err)
      builder:blank()
      if err then
        builder:line({ { "  " .. title, "TuleapChartTitle" } })
        builder:line({ { "  " .. err, "TuleapWarn" } })
      elseif not data then
        builder:line({ { "  " .. title, "TuleapChartTitle" } })
        builder:line({ { "  loading …", "TuleapHint" } })
      else
        builder:append(plot(data, title, chart_width, height, domain))
      end
    end

    if state.mode ~= "burnup" then
      section("Burndown — remaining effort", state.burndown, state.burndown_err)
    end
    if state.mode ~= "burndown" then
      local title = "Burnup — completed vs scope"
      if state.burnup and state.burnup.derived then
        title = title .. "  (derived from burndown)"
      end
      section(title, state.burnup, state.burnup_err)
    end

    if state.burndown and state.burndown.is_under_calculation then
      builder:blank()
      builder:line({ { "  Tuleap is still computing this burndown, values may change.", "TuleapWarn" } })
    end

    win:set_lines(builder.lines)
    win:highlight(builder.highlights)
  end

  local function load()
    milestones.get(milestone_id, function(err, milestone)
      if err then
        return win:error(err)
      end
      state.milestone = milestone
      config.state.last_milestone_id = milestone_id
      win:set_title(milestone.label or ("sprint #" .. milestone_id))
      draw()

      -- The charts are anchored on the milestone's own period so the ideal
      -- line reaches the deadline even when Tuleap's burndown `duration`
      -- counts working days only.
      local start, finish = period(milestone)
      local chart_opts = { period = { start = start, finish = finish } }

      milestones.content(milestone_id, function(_, content)
        state.content = content or {}
        draw()
      end)
      milestones.burndown(milestone_id, function(berr, data)
        state.burndown, state.burndown_err = data, berr
        draw()
      end, chart_opts)
      milestones.burnup(milestone_id, function(uerr, data)
        state.burnup, state.burnup_err = data, uerr
        draw()
      end, chart_opts)
    end)
  end

  win:map(keys.close, function()
    win:close()
  end, "Close")
  win:map(keys.refresh, function()
    require("tuleap.cache").invalidate()
    state.burndown, state.burnup, state.content = nil, nil, nil
    win:loading("Refreshing …")
    load()
  end, "Refresh")
  win:map(keys.toggle, function()
    local index = 1
    for position, mode in ipairs(MODES) do
      if mode == state.mode then
        index = position
      end
    end
    state.mode = MODES[(index % #MODES) + 1]
    draw()
  end, "Cycle charts")
  win:map(keys.content, function()
    win:close()
    require("tuleap.pickers").milestone_content(milestone_id)
  end, "Sprint content")
  win:map(keys.open_browser, function()
    if state.milestone then
      require("tuleap.actions").open_url(milestones.url(state.milestone))
    end
  end, "Open in browser")
  win:map(keys.help, function()
    require("tuleap.util.log").info(
      ("%s cycle charts · %s content · %s refresh · %s browser · %s close"):format(
        keys.toggle,
        keys.content,
        keys.refresh,
        keys.open_browser,
        keys.close
      )
    )
  end, "Help")

  load()
  return win
end

--- Open only one chart, full height.
---@param milestone_id integer
---@param kind "burndown"|"burnup"
function M.chart(milestone_id, kind)
  return M.open(milestone_id, { mode = kind })
end

return M
