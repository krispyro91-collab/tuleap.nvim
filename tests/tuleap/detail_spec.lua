local client = require("tuleap.api.client")
local detail = require("tuleap.ui.detail")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

local ROUTES = {
  ["^/artifacts/%d+$"] = function()
    return fixtures.artifact
  end,
  ["^/artifacts/%d+/changesets$"] = function()
    return fixtures.changesets
  end,
  ["^/trackers/%d+$"] = function()
    return fixtures.tracker
  end,
}

---@return fun() restore
local function stub()
  local original = client.request
  client.request = function(opts, cb)
    for pattern, payload in pairs(ROUTES) do
      if opts.path:match(pattern) then
        return vim.schedule(function()
          cb(nil, payload(), { status = 200, headers = {} })
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

--- Open the detail view and wait for it to finish drawing.
---@return table win
local function open()
  local win = detail.open(1234)
  vim.wait(2000, function()
    return #win:get_lines() > 10 and win.anchors ~= nil
  end, 20)
  vim.wait(200, function()
    return false
  end)
  return win
end

describe("detail view anchors", function()
  local restore

  before_each(function()
    require("tuleap.cache").invalidate()
    restore = stub()
  end)

  after_each(function()
    restore()
    require("tuleap.cache").invalidate()
  end)

  it("anchors every row of a comment to its changeset", function()
    local win = open()
    local lines = win:get_lines()

    local anchored = {}
    for row, anchor in pairs(win.anchors or {}) do
      if anchor.key == "comment" then
        anchored[anchor.value] = (anchored[anchor.value] or 0) + 1
      end
    end

    -- Both fixture comments must be reachable...
    assert.is_not_nil(anchored[1], "first comment not anchored")
    assert.is_not_nil(anchored[2], "second comment not anchored")
    -- ...and over more than just the author line, so the cursor can sit in
    -- the body and still be understood as "this comment".
    assert.is_true(anchored[1] >= 2, "comment anchored on too few rows")

    -- The anchored row really is where that comment is drawn.
    for row, anchor in pairs(win.anchors or {}) do
      if anchor.key == "comment" and anchor.value == 1 then
        local line = lines[row + 1] or ""
        assert.is_true(
          line:find("Alice", 1, true) ~= nil or line:find("Reproduced", 1, true) ~= nil,
          ("row %d is not part of the first comment: %q"):format(row, line)
        )
      end
    end
    win:close()
  end)

  it("does not anchor the header or the field rows", function()
    local win = open()
    for row = 0, 5 do
      local anchor = (win.anchors or {})[row]
      assert.is_true(
        anchor == nil or anchor.key ~= "comment",
        ("header row %d should not be a comment"):format(row)
      )
    end
    win:close()
  end)
end)
