local date = require("tuleap.util.date")

describe("date", function()
  it("parses ISO-8601 timestamps", function()
    local stamp = date.parse("2026-01-05T08:30:00+01:00")
    assert.is_number(stamp)
    assert.equals("2026-01-05", date.format(stamp))
  end)

  it("returns nil for junk", function()
    assert.is_nil(date.parse(nil))
    assert.is_nil(date.parse(""))
    assert.is_nil(date.parse("not a date"))
  end)

  it("passes numbers through", function()
    assert.equals(1234, date.parse(1234))
  end)

  it("counts whole days", function()
    local a = date.parse("2026-01-01T00:00:00+00:00")
    local b = date.parse("2026-01-11T00:00:00+00:00")
    assert.equals(10, date.days_between(a, b))
  end)

  it("honours the timezone offset the string carries", function()
    -- The same instant written in three zones must parse identically.
    local utc = date.parse("2026-01-05T08:30:00Z")
    local plus2 = date.parse("2026-01-05T10:30:00+02:00")
    local minus5 = date.parse("2026-01-05T03:30:00-05:00")
    assert.equals(utc, plus2)
    assert.equals(utc, minus5)
    -- And it must be the real instant, not a local reinterpretation.
    assert.equals("2026-01-05 08:30", os.date("!%Y-%m-%d %H:%M", utc))
  end)

  it("does not report a fresh timestamp as being in the future", function()
    -- Regression: ignoring the offset made a just-created artifact look like
    -- it was submitted "in 59 minutes".
    local now = os.time()
    local server = os.date("!%Y-%m-%dT%H:%M:%S+00:00", now)
    local parsed = date.parse(server)
    assert.is_true(math.abs(parsed - now) <= 1, ("parsed %d vs now %d"):format(parsed, now))
    assert.is_true(date.relative(server):find("ago") ~= nil or date.relative(server) == "just now")
  end)

  it("reads an offset-less date as local noon", function()
    local stamp = date.parse("2026-01-05")
    assert.equals("2026-01-05", os.date("%Y-%m-%d", stamp))
    assert.equals("12", os.date("%H", stamp))
  end)

  it("formats relative dates in both directions", function()
    assert.is_true(date.relative(os.time() - 3 * 86400):find("ago") ~= nil)
    assert.is_true(date.relative(os.time() + 3 * 86400):find("in ") ~= nil)
    assert.equals("—", date.relative(nil))
  end)
end)
