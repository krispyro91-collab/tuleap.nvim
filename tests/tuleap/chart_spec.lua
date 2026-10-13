local chart = require("tuleap.ui.chart")

---@param lines string[]
---@return string
local function joined(lines)
  return table.concat(lines, "\n")
end

describe("chart", function()
  local series = {
    { name = "Remaining", points = { { x = 0, y = 10 }, { x = 5, y = 6 }, { x = 10, y = 0 } } },
  }

  it("renders a chart with axes, ticks and a legend", function()
    local out = chart.render({ series = series, width = 60, height = 10, title = "Burndown" })
    assert.is_true(#out.lines > 10)
    assert.equals("  Burndown", out.lines[1])
    assert.is_true(joined(out.lines):find("└", 1, true) ~= nil)
    assert.is_true(joined(out.lines):find("Remaining", 1, true) ~= nil)
  end)

  it("keeps every line within the requested width", function()
    local out = chart.render({ series = series, width = 48, height = 8 })
    for _, line in ipairs(out.lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 48, "line too wide: " .. line)
    end
  end)

  it("supports every rendering style", function()
    for _, style in ipairs({ "braille", "blocks", "ascii" }) do
      local out = chart.render({ series = series, width = 50, height = 8, style = style })
      assert.is_true(#out.lines > 5, style .. " produced no output")
      assert.is_true(#out.highlights > 0, style .. " produced no highlights")
    end
    -- The ascii style must stay inside ASCII.
    local ascii = chart.render({ series = series, width = 50, height = 8, style = "ascii" })
    assert.is_nil(joined(ascii.lines):find("[\128-\255]"))
  end)

  it("honours an explicit x domain", function()
    local out = chart.render({
      series = series,
      width = 60,
      height = 8,
      x_min = -10,
      x_max = 20,
      x_format = function(x)
        return tostring(math.floor(x))
      end,
    })
    assert.is_true(joined(out.lines):find("-10", 1, true) ~= nil)
    assert.is_true(joined(out.lines):find("20", 1, true) ~= nil)
  end)

  it("degrades gracefully without data", function()
    local out = chart.render({ series = {}, width = 40, height = 6 })
    assert.equals(1, #out.lines)
  end)

  it("never emits a highlight past the end of its line", function()
    local out = chart.render({ series = series, width = 60, height = 10, title = "x" })
    for _, item in ipairs(out.highlights) do
      local line = out.lines[item.row + 1]
      assert.is_not_nil(line)
      if item.end_col ~= -1 then
        assert.is_true(item.end_col <= #line, "highlight overflows line " .. item.row)
      end
      assert.is_true(item.col <= #line)
    end
  end)

  it("builds sparklines and progress bars", function()
    assert.equals(8, vim.fn.strchars(chart.sparkline({ 1, 2, 3, 4, 5, 6, 7, 8 })))
    assert.equals(5, vim.fn.strchars(chart.sparkline({ 1, 2, 3, 4, 5, 6, 7, 8 }, { width = 5 })))
    local bar = chart.progress_bar(0.5, 10)
    assert.is_true(bar:find("50%%") ~= nil)
  end)
end)
