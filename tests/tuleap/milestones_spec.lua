local client = require("tuleap.api.client")
local milestones = require("tuleap.api.milestones")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

---@param routes table<string, any>
---@param missing string[]? paths that must answer an error
local function stub(routes, missing)
  local original = client.request
  client.request = function(opts, cb)
    for _, pattern in ipairs(missing or {}) do
      if opts.path:match(pattern) then
        return vim.schedule(function()
          cb("HTTP 404: unknown route")
        end)
      end
    end
    for pattern, payload in pairs(routes) do
      if opts.path:match(pattern) then
        return vim.schedule(function()
          cb(nil, payload, { status = 200, headers = {} })
        end)
      end
    end
    vim.schedule(function()
      cb("HTTP 404: no stub for " .. opts.path)
    end)
  end
  return function()
    client.request = original
  end
end

---@param fn fun(done: fun())
local function sync(fn)
  local finished = false
  fn(function()
    finished = true
  end)
  assert.is_true(vim.wait(2000, function()
    return finished
  end, 10), "callback never fired")
end

describe("milestones.burndown", function()
  it("normalises points_with_date and adds the ideal line", function()
    local restore = stub({ ["burndown"] = fixtures.burndown })
    sync(function(done)
      milestones.burndown(555, function(err, data)
        assert.is_nil(err)
        assert.equals(2, #data.series)
        assert.equals("Remaining", data.series[1].name)
        assert.equals("Ideal", data.series[2].name)
        assert.equals(10, #data.series[1].points)
        assert.equals(38, data.capacity)
        -- The ideal line runs from the capacity down to zero.
        assert.equals(38, data.series[2].points[1].y)
        assert.equals(0, data.series[2].points[2].y)
        done()
      end)
    end)
    restore()
  end)

  it("reports an empty burndown instead of drawing nothing", function()
    local restore = stub({ ["burndown"] = { duration = 10, points = {} } })
    sync(function(done)
      milestones.burndown(555, function(err)
        assert.is_true(err:find("no burndown points") ~= nil)
        done()
      end)
    end)
    restore()
  end)
end)

describe("milestones.burnup", function()
  it("uses the native endpoint when the instance exposes it", function()
    local restore = stub({
      ["burnup"] = {
        start_date = fixtures.burndown.start_date,
        duration = 14,
        points_with_date = {
          { date = fixtures.burndown.start_date, team_effort = 0, total_effort = 38 },
          { date = fixtures.burndown.points_with_date[5].date, team_effort = 12, total_effort = 40 },
        },
      },
    })
    sync(function(done)
      milestones.burnup(555, function(err, data)
        assert.is_nil(err)
        assert.is_nil(data.derived)
        assert.equals("Completed", data.series[1].name)
        assert.equals("Scope", data.series[2].name)
        assert.equals(12, data.series[1].points[2].y)
        assert.equals(40, data.series[2].points[2].y)
        done()
      end)
    end)
    restore()
  end)

  it("derives a burnup from the burndown when /burnup is missing", function()
    local restore = stub({ ["burndown"] = fixtures.burndown }, { "burnup" })
    sync(function(done)
      milestones.burnup(555, function(err, data)
        assert.is_nil(err)
        assert.is_true(data.derived)
        assert.equals("Completed", data.series[1].name)
        -- completed = capacity - remaining, so it starts low and grows.
        local completed = data.series[1].points
        assert.is_true(completed[1].y < completed[#completed].y)
        -- the scope line spans the whole sprint
        assert.equals(2, #data.series[2].points)
        assert.equals(data.series[2].points[1].y, data.series[2].points[2].y)
        done()
      end)
    end)
    restore()
  end)
end)
