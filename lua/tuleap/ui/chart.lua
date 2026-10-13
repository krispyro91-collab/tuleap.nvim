---@mod tuleap.ui.chart Terminal line charts
---
--- Renders line charts into buffer lines plus a list of highlight ranges.
--- Three resolutions are available:
---   * `braille` — 2x4 dots per cell (U+28xx), the default
---   * `blocks`  — upper/lower half blocks, 1x2 per cell
---   * `ascii`   — one marker character per cell, no Unicode at all
---
--- Usage:
--- >lua
---   local out = require("tuleap.ui.chart").render({
---     series = { { name = "Remaining", points = { { x = 1, y = 10 } } } },
---     width = 80, height = 16,
---   })
---   vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
--- <

local bit = require("bit")

local M = {}

---@alias tuleap.Point {x: number, y: number}

--- dot bit for (x, y) inside a braille cell
local BRAILLE = {
  [0] = { [0] = 0x01, [1] = 0x02, [2] = 0x04, [3] = 0x40 },
  [1] = { [0] = 0x08, [1] = 0x10, [2] = 0x20, [3] = 0x80 },
}

local BLOCKS = { [1] = "▀", [2] = "▄", [3] = "█" }

local STYLES = {
  braille = { xres = 2, yres = 4 },
  blocks = { xres = 1, yres = 2 },
  ascii = { xres = 1, yres = 1 },
}

local MARKERS = { "o", "x", "+", "*", "#", "." }

--------------------------------------------------------------------------- canvas

---@class tuleap.Canvas
---@field w integer cells
---@field h integer cells
local Canvas = {}
Canvas.__index = Canvas

---@param w integer
---@param h integer
---@param style string
---@return tuleap.Canvas
function Canvas.new(w, h, style)
  local res = STYLES[style] or STYLES.braille
  return setmetatable({
    w = math.max(1, w),
    h = math.max(1, h),
    style = STYLES[style] and style or "braille",
    xres = res.xres,
    yres = res.yres,
    cells = {},
  }, Canvas)
end

---@return integer width in plottable pixels
function Canvas:pixel_width()
  return self.w * self.xres
end

---@return integer height in plottable pixels
function Canvas:pixel_height()
  return self.h * self.yres
end

--- Light up one pixel.
---@param px integer
---@param py integer
---@param hl string?
---@param char string? only honoured by the ascii style
function Canvas:set(px, py, hl, char)
  px, py = math.floor(px + 0.5), math.floor(py + 0.5)
  if px < 0 or py < 0 or px >= self:pixel_width() or py >= self:pixel_height() then
    return
  end
  local cx, cy = math.floor(px / self.xres), math.floor(py / self.yres)
  local key = cy * self.w + cx
  local cell = self.cells[key]
  if not cell then
    cell = { mask = 0 }
    self.cells[key] = cell
  end
  if self.style == "braille" then
    cell.mask = bit.bor(cell.mask, BRAILLE[px % 2][py % 4])
  elseif self.style == "blocks" then
    cell.mask = bit.bor(cell.mask, (py % 2 == 0) and 1 or 2)
  else
    cell.char = char or "o"
    cell.mask = 1
  end
  cell.hl = hl or cell.hl
end

--- Bresenham, in pixel space.
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param hl string?
---@param opts {dashed: boolean?, char: string?}?
function Canvas:line(x0, y0, x1, y1, hl, opts)
  opts = opts or {}
  x0, y0, x1, y1 =
    math.floor(x0 + 0.5), math.floor(y0 + 0.5), math.floor(x1 + 0.5), math.floor(y1 + 0.5)
  local dx = math.abs(x1 - x0)
  local dy = -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local step = 0
  while true do
    -- A dashed line draws two pixels then skips two.
    if not opts.dashed or (step % 4) < 2 then
      self:set(x0, y0, hl, opts.char)
    end
    step = step + 1
    if x0 == x1 and y0 == y1 then
      break
    end
    local err2 = 2 * err
    if err2 >= dy then
      if x0 == x1 then
        break
      end
      err = err + dy
      x0 = x0 + sx
    end
    if err2 <= dx then
      if y0 == y1 then
        break
      end
      err = err + dx
      y0 = y0 + sy
    end
  end
end

---@param px integer
---@param hl string?
function Canvas:vline(px, hl, dashed)
  self:line(px, 0, px, self:pixel_height() - 1, hl, { dashed = dashed, char = "|" })
end

---@param cx integer 0-based cell column
---@param cy integer 0-based cell row
---@return string? char, string? hl
function Canvas:cell(cx, cy)
  local cell = self.cells[cy * self.w + cx]
  if not cell or cell.mask == 0 then
    return nil, nil
  end
  if self.style == "braille" then
    return vim.fn.nr2char(0x2800 + cell.mask), cell.hl
  elseif self.style == "blocks" then
    return BLOCKS[cell.mask] or "█", cell.hl
  end
  return cell.char or "o", cell.hl
end

--------------------------------------------------------------------------- scales

--- Round `value` up to a visually pleasant number (1, 2, 2.5, 5, 10, ...).
---@param value number
---@return number
local function nice_num(value, round)
  if value <= 0 then
    return 1
  end
  local exp = math.floor(math.log(value) / math.log(10))
  local frac = value / 10 ^ exp
  local nice
  if round then
    nice = (frac < 1.5 and 1) or (frac < 3 and 2) or (frac < 7 and 5) or 10
  else
    nice = (frac <= 1 and 1) or (frac <= 2 and 2) or (frac <= 5 and 5) or 10
  end
  return nice * 10 ^ exp
end

--- Pick at most `count` round tick values covering [lo, hi].
---@param lo number
---@param hi number
---@param count integer
---@return number[] ticks, number lo, number hi
local function ticks_for(lo, hi, count)
  if hi <= lo then
    hi = lo + 1
  end
  local step = nice_num((hi - lo) / math.max(1, count - 1), true)
  local start = math.floor(lo / step) * step
  local stop = math.ceil(hi / step) * step
  local out = {}
  local value = start
  -- Guard against a pathological step producing an endless loop.
  for _ = 1, 64 do
    out[#out + 1] = value
    if value >= stop - 1e-9 then
      break
    end
    value = value + step
  end
  return out, start, stop
end

---@param value number
---@return string
local function default_y_format(value)
  if math.abs(value - math.floor(value + 0.5)) < 1e-6 then
    return tostring(math.floor(value + 0.5))
  end
  return ("%.1f"):format(value)
end

--------------------------------------------------------------------------- render

---@class tuleap.ChartSpec
---@field series {name: string, points: tuleap.Point[], style: string?, hl: string?}[]
---@field width integer total columns the chart may use
---@field height integer plot height in rows
---@field title string?
---@field style string? braille|blocks|ascii
---@field x_format fun(x: number): string
---@field y_format fun(y: number): string
---@field y_min number?
---@field y_max number?
---@field x_min number? pin the horizontal domain (to align several charts)
---@field x_max number?
---@field markers {x: number, label: string?, hl: string?}[]?
---@field legend boolean?

---@class tuleap.ChartOutput
---@field lines string[]
---@field highlights {row: integer, col: integer, end_col: integer, hl: string}[]
---@field height integer

--- Render a chart.
---@param spec tuleap.ChartSpec
---@return tuleap.ChartOutput
function M.render(spec)
  local config = require("tuleap.config")
  local style = spec.style or config.options.chart.style
  local colors = config.options.chart.colors
  local width = math.max(24, spec.width or 80)
  local height = math.max(4, spec.height or 16)
  local y_format = spec.y_format or default_y_format
  local x_format = spec.x_format or tostring

  local lines, highlights = {}, {}
  local function push(line)
    lines[#lines + 1] = line
    return #lines - 1 -- 0-based row index, as extmarks want
  end
  local function hl(row, col, end_col, group)
    if group then
      highlights[#highlights + 1] = { row = row, col = col, end_col = end_col, hl = group }
    end
  end

  -- ---------------------------------------------------------------- domain
  local xmin, xmax, ymin, ymax
  for _, series in ipairs(spec.series) do
    for _, point in ipairs(series.points or {}) do
      xmin = math.min(xmin or point.x, point.x)
      xmax = math.max(xmax or point.x, point.x)
      ymin = math.min(ymin or point.y, point.y)
      ymax = math.max(ymax or point.y, point.y)
    end
  end
  for _, marker in ipairs(spec.markers or {}) do
    if marker.x then
      xmin = math.min(xmin or marker.x, marker.x)
      xmax = math.max(xmax or marker.x, marker.x)
    end
  end

  if not xmin and not spec.x_min then
    return { lines = { "  (no data points)" }, highlights = {}, height = 1 }
  end
  -- An explicit domain lets several charts of the same sprint share one x axis.
  xmin = spec.x_min or xmin
  xmax = spec.x_max or xmax
  if xmax <= xmin then
    xmax = xmin + 1
  end

  ymin = spec.y_min or math.min(0, ymin or 0)
  ymax = spec.y_max or (ymax or 1)
  local yticks, ylo, yhi = ticks_for(ymin, ymax, math.max(3, math.min(8, math.floor(height / 2))))
  ymin, ymax = ylo, yhi
  if ymax == ymin then
    ymax = ymin + 1
  end

  -- ------------------------------------------------------------ geometry
  local label_w = 0
  for _, tick in ipairs(yticks) do
    label_w = math.max(label_w, vim.fn.strdisplaywidth(y_format(tick)))
  end
  label_w = math.min(label_w, 8)

  local plot_w = width - label_w - 2
  if plot_w < 8 then
    plot_w = math.max(8, width - 4)
    label_w = math.max(0, width - plot_w - 2)
  end
  local plot_h = height

  local canvas = Canvas.new(plot_w, plot_h, style)
  local pw, ph = canvas:pixel_width(), canvas:pixel_height()

  local function to_px(x)
    return (x - xmin) / (xmax - xmin) * (pw - 1)
  end
  local function to_py(y)
    return (1 - (y - ymin) / (ymax - ymin)) * (ph - 1)
  end

  -- -------------------------------------------------------------- plotting
  local series_hl = {}
  for index, series in ipairs(spec.series) do
    local group = series.hl or colors[((index - 1) % #colors) + 1]
    series_hl[index] = group
    local marker = MARKERS[((index - 1) % #MARKERS) + 1]
    local points = series.points or {}
    local dashed = series.style == "dashed"
    if #points == 1 then
      canvas:set(to_px(points[1].x), to_py(points[1].y), group, marker)
    end
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      if series.style == "step" then
        canvas:line(to_px(a.x), to_py(a.y), to_px(b.x), to_py(a.y), group, { char = marker })
        canvas:line(to_px(b.x), to_py(a.y), to_px(b.x), to_py(b.y), group, { char = marker })
      else
        canvas:line(
          to_px(a.x),
          to_py(a.y),
          to_px(b.x),
          to_py(b.y),
          group,
          { dashed = dashed, char = marker }
        )
      end
    end
  end

  for _, marker in ipairs(spec.markers or {}) do
    if marker.x and marker.x >= xmin and marker.x <= xmax then
      canvas:vline(to_px(marker.x), marker.hl or "TuleapChartMarker", true)
    end
  end

  -- ----------------------------------------------------------------- title
  if spec.title then
    local row = push("  " .. spec.title)
    hl(row, 0, -1, "TuleapChartTitle")
  end

  -- -------------------------------------------------- y labels + plot rows
  --- Row holding a given y value, or nil when it falls outside the plot.
  local label_at = {}
  for _, tick in ipairs(yticks) do
    local row = math.floor((1 - (tick - ymin) / (ymax - ymin)) * (plot_h - 1) + 0.5)
    if row >= 0 and row < plot_h then
      label_at[row] = y_format(tick)
    end
  end

  for row = 0, plot_h - 1 do
    local label = label_at[row]
    local prefix = (" "):rep(math.max(0, label_w - vim.fn.strdisplaywidth(label or "")))
      .. (label or "")
      .. " "
    local axis = label and "┤" or "│"
    if style == "ascii" then
      axis = label and "+" or "|"
    end
    local parts = { prefix, axis }
    local byte_at = #prefix + #axis
    local spans = {}
    local pending = nil
    for cx = 0, plot_w - 1 do
      local char, group = canvas:cell(cx, row)
      char = char or " "
      parts[#parts + 1] = char
      if group then
        if pending and pending.hl == group and pending.end_col == byte_at then
          pending.end_col = byte_at + #char
        else
          if pending then
            spans[#spans + 1] = pending
          end
          pending = { col = byte_at, end_col = byte_at + #char, hl = group }
        end
      elseif pending then
        spans[#spans + 1] = pending
        pending = nil
      end
      byte_at = byte_at + #char
    end
    if pending then
      spans[#spans + 1] = pending
    end

    local line_row = push((table.concat(parts):gsub("%s+$", "")))
    hl(line_row, 0, #prefix, "TuleapChartLabel")
    hl(line_row, #prefix, #prefix + #axis, "TuleapChartAxis")
    for _, span in ipairs(spans) do
      hl(line_row, span.col, span.end_col, span.hl)
    end
  end

  -- ---------------------------------------------------------------- x axis
  local corner, dash = "└", "─"
  if style == "ascii" then
    corner, dash = "+", "-"
  end
  local axis_row = push((" "):rep(label_w + 1) .. corner .. dash:rep(plot_w))
  hl(axis_row, label_w + 1, -1, "TuleapChartAxis")

  -- ------------------------------------------------------------ x tick row
  local tick_count = math.max(2, math.min(6, math.floor(plot_w / 12)))
  local tick_line = { (" "):rep(label_w + 2) }
  local filled = 0 -- columns already written inside the plot area
  for index = 0, tick_count - 1 do
    local value = xmin + (xmax - xmin) * (index / (tick_count - 1))
    local text = x_format(value)
    local text_w = vim.fn.strdisplaywidth(text)
    -- Centre the label on its tick, then clamp it inside the plot area.
    local col = math.floor((index / (tick_count - 1)) * (plot_w - 1) - text_w / 2 + 0.5)
    col = math.max(0, math.min(col, plot_w - text_w))
    if col >= filled then
      tick_line[#tick_line + 1] = (" "):rep(col - filled) .. text
      filled = col + text_w + 1
    end
  end
  local tick_row = push(table.concat(tick_line))
  hl(tick_row, 0, -1, "TuleapChartLabel")

  -- ---------------------------------------------------------------- legend
  if spec.legend ~= false then
    local parts = { (" "):rep(label_w + 2) }
    local byte_at = #parts[1]
    local spans = {}
    for index, series in ipairs(spec.series) do
      local glyph = series.style == "dashed" and "┈┈" or "──"
      if style == "ascii" then
        glyph = series.style == "dashed" and ".." or "--"
      end
      local chunk = ("%s %s"):format(glyph, series.name or ("series " .. index))
      spans[#spans + 1] = { col = byte_at, end_col = byte_at + #glyph, hl = series_hl[index] }
      parts[#parts + 1] = chunk
      byte_at = byte_at + #chunk
      if index < #spec.series then
        parts[#parts + 1] = "   "
        byte_at = byte_at + 3
      end
    end
    local legend_row = push(table.concat(parts))
    hl(legend_row, 0, -1, "TuleapChartLabel")
    for _, span in ipairs(spans) do
      hl(legend_row, span.col, span.end_col, span.hl)
    end
  end

  return { lines = lines, highlights = highlights, height = #lines }
end

--------------------------------------------------------------------------- extras

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- One-line sparkline, handy inside picker previews.
---@param values number[]
---@param opts {width: integer?, min: number?, max: number?}?
---@return string
function M.sparkline(values, opts)
  opts = opts or {}
  if #values == 0 then
    return ""
  end
  local lo = opts.min or math.min(unpack(values))
  local hi = opts.max or math.max(unpack(values))
  if hi <= lo then
    hi = lo + 1
  end

  local sampled = values
  local width = opts.width
  if width and #values > width then
    sampled = {}
    for index = 1, width do
      sampled[index] = values[math.ceil(index / width * #values)]
    end
  end

  local out = {}
  for _, value in ipairs(sampled) do
    local slot = math.floor((value - lo) / (hi - lo) * (#SPARK - 1) + 0.5) + 1
    out[#out + 1] = SPARK[math.max(1, math.min(#SPARK, slot))]
  end
  return table.concat(out)
end

--- Unicode progress bar: `████████░░░░  62%`.
---@param ratio number between 0 and 1
---@param width integer
---@param opts {percent: boolean?, filled: string?, empty: string?}?
---@return string bar, integer filled_bytes
function M.progress_bar(ratio, width, opts)
  opts = opts or {}
  ratio = math.max(0, math.min(1, ratio or 0))
  local filled_char = opts.filled or "█"
  local empty_char = opts.empty or "░"
  local filled = math.floor(ratio * width + 0.5)
  local bar = filled_char:rep(filled) .. empty_char:rep(width - filled)
  if opts.percent ~= false then
    bar = ("%s %3d%%"):format(bar, math.floor(ratio * 100 + 0.5))
  end
  return bar, filled * #filled_char
end

M.Canvas = Canvas

return M
