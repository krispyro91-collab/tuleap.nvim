local artifacts = require("tuleap.api.artifacts")
local client = require("tuleap.api.client")
local milestones = require("tuleap.api.milestones")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

---@param handler fun(method: string, path: string, body: table?): string?, any
---@return fun() restore, table writes
local function stub(handler)
  local original = client.request
  local writes = {}
  client.request = function(opts, cb)
    local method = (opts.method or "GET"):upper()
    local body = type(opts.body) == "table" and opts.body or nil
    if method ~= "GET" then
      writes[#writes + 1] = { method = method, path = opts.path, body = body }
    end
    local err, data = handler(method, opts.path, body)
    vim.schedule(function()
      cb(err, data, { status = err and 400 or 200, headers = {} })
    end)
  end
  return function()
    client.request = original
  end, writes
end

---@param fn fun(done: fun())
local function sync(fn)
  local finished = false
  fn(function()
    finished = true
  end)
  assert.is_true(vim.wait(2000, function()
    return finished
  end, 5), "callback never fired")
end

--- Routes for an epic that already has children.
---@param overrides table<string, fun(method: string, path: string, body: table?): string?, any>?
local function epic_routes(overrides)
  overrides = overrides or {}
  return function(method, path, body)
    if overrides[path] then
      return overrides[path](method, path, body)
    end
    if path == "/artifacts/42" then
      return nil, fixtures.epic
    elseif path == "/trackers/8" then
      return nil, fixtures.epic_tracker
    end
    return "HTTP 404: no stub for " .. method .. " " .. path
  end
end

describe("artifacts.add_link", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("appends the child while keeping the existing links", function()
    local restore, writes = stub(epic_routes())
    sync(function(done)
      artifacts.add_link(42, 1234, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.added)
        done()
      end)
    end)

    assert.equals(1, #writes)
    assert.equals("PUT", writes[1].method)
    assert.equals("/artifacts/42", writes[1].path)
    local links = writes[1].body.values[1].links
    assert.equals(22, writes[1].body.values[1].field_id)
    -- The two existing children must survive the replace-the-whole-list write.
    assert.equals(3, #links)
    assert.equals(777, links[1].id)
    assert.equals(888, links[2].id)
    assert.equals(1234, links[3].id)
    assert.equals("_is_child", links[3].type)
    restore()
  end)

  it("honours a custom link nature", function()
    local restore, writes = stub(epic_routes())
    sync(function(done)
      artifacts.add_link(42, 1234, { nature = "_depends_on" }, function(err)
        assert.is_nil(err)
        done()
      end)
    end)
    assert.equals("_depends_on", writes[1].body.values[1].links[3].type)
    restore()
  end)

  it("is idempotent and writes nothing when already linked", function()
    local restore, writes = stub(epic_routes())
    sync(function(done)
      artifacts.add_link(42, 777, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.already)
        done()
      end)
    end)
    assert.equals(0, #writes, "an already-linked child must not trigger a write")
    restore()
  end)

  it("links a parent that has none yet, when the endpoint confirms it is empty", function()
    -- Tuleap omits the art_link field from `values` until the artifact has a
    -- link, so absence must not be mistaken for unreadable.
    local fresh = vim.deepcopy(fixtures.epic)
    table.remove(fresh.values, 3)
    local restore, writes = stub(epic_routes({
      ["/artifacts/42"] = function()
        return nil, fresh
      end,
      ["/artifacts/42/linked_artifacts"] = function()
        return nil, { collection = {} }
      end,
    }))
    sync(function(done)
      artifacts.add_link(42, 1234, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.added)
        done()
      end)
    end)
    assert.equals(1, #writes)
    assert.same({ { id = 1234, type = "_is_child" } }, writes[1].body.values[1].links)
    restore()
  end)

  it("refuses when the payload hid links the endpoint can see", function()
    local fresh = vim.deepcopy(fixtures.epic)
    table.remove(fresh.values, 3)
    local restore, writes = stub(epic_routes({
      ["/artifacts/42"] = function()
        return nil, fresh
      end,
      ["/artifacts/42/linked_artifacts"] = function()
        return nil, { collection = { { id = 777 }, { id = 888 } } }
      end,
    }))
    sync(function(done)
      artifacts.add_link(42, 1234, {}, function(err)
        assert.is_not_nil(err)
        assert.is_true(err:find("refusing to replace", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(0, #writes)
    restore()
  end)

  it("refuses to write when the current links cannot be read", function()
    local blind = vim.deepcopy(fixtures.epic)
    -- No value for the art_link field: we cannot know what we would erase.
    table.remove(blind.values, 3)
    local restore, writes = stub(epic_routes({
      ["/artifacts/42"] = function()
        return nil, blind
      end,
      ["/artifacts/42/linked_artifacts"] = function()
        return "HTTP 403: forbidden"
      end,
    }))
    sync(function(done)
      artifacts.add_link(42, 1234, {}, function(err)
        assert.is_not_nil(err)
        assert.is_true(err:find("refusing to replace", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(0, #writes, "must not PUT when the links are unknown")
    restore()
  end)

  it("explains when the tracker has no artifact link field", function()
    local restore, writes = stub(epic_routes({
      ["/trackers/8"] = function()
        return nil, fixtures.tracker -- the bug tracker, which has no art_link
      end,
    }))
    sync(function(done)
      artifacts.add_link(42, 1234, {}, function(err)
        assert.is_true(err:find("no artifact link field", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(0, #writes)
    restore()
  end)
end)

describe("artifacts.links", function()
  it("reads the links out of the artifact's own link field", function()
    local restore = stub(epic_routes({
      ["/artifacts/777"] = function()
        return nil, { id = 777, xref = "story #777", title = "a child" }
      end,
      ["/artifacts/888"] = function()
        return nil, { id = 888, xref = "story #888", title = "another child" }
      end,
      -- The dedicated route lies on this instance; it must not be consulted.
      ["/artifacts/42/linked_artifacts"] = function()
        return nil, { collection = {} }
      end,
    }))
    sync(function(done)
      artifacts.links(42, "forward", function(err, kids)
        assert.is_nil(err)
        assert.equals(2, #kids)
        assert.equals("story #777", kids[1].xref)
        assert.equals("_is_child", kids[1].type)
        done()
      end)
    end)
    restore()
  end)

  it("can skip resolving titles", function()
    local restore = stub(epic_routes())
    sync(function(done)
      artifacts.links(42, "forward", function(err, kids)
        assert.is_nil(err)
        assert.equals(2, #kids)
        assert.equals(777, kids[1].id)
        done()
      end, { resolve = false })
    end)
    restore()
  end)

  it("falls back to the dedicated route when no link field is exposed", function()
    local blind = vim.deepcopy(fixtures.epic)
    table.remove(blind.values, 3)
    local restore = stub(epic_routes({
      ["/artifacts/42"] = function()
        return nil, blind
      end,
      ["/artifacts/42/linked_artifacts"] = function()
        return nil, { collection = { { id = 999, xref = "bug #999" } } }
      end,
    }))
    sync(function(done)
      artifacts.links(42, "forward", function(err, kids)
        assert.is_nil(err)
        assert.equals(1, #kids)
        assert.equals("bug #999", kids[1].xref)
        done()
      end)
    end)
    restore()
  end)
end)

describe("milestones.add_content", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("adds incrementally with PATCH when the route supports it", function()
    local restore, writes = stub(function(method, path)
      if method == "PATCH" and path == "/milestones/555/content" then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end)
    sync(function(done)
      milestones.add_content(555, { 1234 }, function(err)
        assert.is_nil(err)
        done()
      end)
    end)
    assert.equals(1, #writes)
    assert.equals("PATCH", writes[1].method)
    assert.same({ { id = 1234 } }, writes[1].body.add)
    restore()
  end)

  it("falls back to PUT with the merged id list when PATCH is unsupported", function()
    local restore, writes = stub(function(method, path)
      if method == "PATCH" then
        return "HTTP 405: Method Not Allowed"
      elseif method == "GET" and path == "/milestones/555/content" then
        return nil, { { id = 11 }, { id = 22 } }
      elseif method == "PUT" then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end)
    sync(function(done)
      milestones.add_content(555, { 1234 }, function(err)
        assert.is_nil(err)
        done()
      end)
    end)

    local put = writes[#writes]
    assert.equals("PUT", put.method)
    -- The existing content must be preserved, not replaced by the new id.
    assert.same({ 11, 22, 1234 }, put.body.ids)
    restore()
  end)

  it("does not duplicate an artifact already planned", function()
    local restore, writes = stub(function(method, path)
      if method == "PATCH" then
        return "HTTP 405"
      elseif method == "GET" and path == "/milestones/555/content" then
        return nil, { { id = 11 }, { id = 1234 } }
      elseif method == "PUT" then
        return nil, {}
      end
      return "HTTP 404"
    end)
    sync(function(done)
      milestones.add_content(555, { 1234 }, function()
        done()
      end)
    end)
    assert.same({ 11, 1234 }, writes[#writes].body.ids)
    restore()
  end)

  it("gives up rather than truncate when the content cannot be read", function()
    local restore, writes = stub(function(method)
      if method == "PATCH" then
        return "HTTP 405: Method Not Allowed"
      end
      return "HTTP 403: forbidden"
    end)
    sync(function(done)
      milestones.add_content(555, { 1234 }, function(err)
        assert.is_true(err:find("405", 1, true) ~= nil)
        done()
      end)
    end)
    for _, write in ipairs(writes) do
      assert.is_not.equals("PUT", write.method, "must not PUT a content list it could not read")
    end
    restore()
  end)
end)

describe("artifacts.remove_link", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("drops the child and writes the remaining links back", function()
    local restore, writes = stub(epic_routes())
    sync(function(done)
      artifacts.remove_link(42, 777, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.removed)
        done()
      end)
    end)

    assert.equals(1, #writes)
    assert.equals("PUT", writes[1].method)
    assert.equals("/artifacts/42", writes[1].path)
    -- Only 777 goes; the sibling must survive the whole-list write.
    assert.same({ { id = 888, type = "_is_child" } }, writes[1].body.values[1].links)
    restore()
  end)

  it("writes nothing when the child is not linked there", function()
    local restore, writes = stub(epic_routes())
    sync(function(done)
      artifacts.remove_link(42, 1234, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.absent)
        done()
      end)
    end)
    assert.equals(0, #writes, "a child that is not there must not trigger a write")
    restore()
  end)

  it("writes nothing when the link field is not exposed at all", function()
    -- Absence of the field is indistinguishable from "cannot read it", and an
    -- empty list is a change nobody asked for either way.
    local blind = vim.deepcopy(fixtures.epic)
    table.remove(blind.values, 3)
    local restore, writes = stub(epic_routes({
      ["/artifacts/42"] = function()
        return nil, blind
      end,
    }))
    sync(function(done)
      artifacts.remove_link(42, 777, {}, function(err, result)
        assert.is_nil(err)
        assert.is_true(result.absent)
        done()
      end)
    end)
    assert.equals(0, #writes)
    restore()
  end)

  it("explains when the tracker has no artifact link field", function()
    local restore, writes = stub(epic_routes({
      ["/trackers/8"] = function()
        return nil, fixtures.tracker
      end,
    }))
    sync(function(done)
      artifacts.remove_link(42, 777, {}, function(err)
        assert.is_true(err:find("no artifact link field", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(0, #writes)
    restore()
  end)
end)

describe("artifacts.parent_on", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  --- An artifact whose reverse links are a sprint and an epic, as
  --- /artifacts/{id}/linked_artifacts?direction=reverse answers them.
  local function reverse_routes(collection)
    return function(method, path)
      if path == "/artifacts/1234" then
        return nil, { id = 1234, xref = "bug #1234", tracker = { id = 7 }, values = {} }
      elseif path == "/artifacts/1234/linked_artifacts" then
        return nil, { collection = collection }
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end
  end

  it("picks the parent sitting on one of the given trackers", function()
    local restore = stub(reverse_routes({
      { id = 555, title = "Sprint 59", tracker = { id = 12, label = "Sprints" } },
      { id = 42, title = "Single sign-on support", tracker = { id = 8, label = "Epics" } },
    }))
    sync(function(done)
      artifacts.parent_on(1234, { [12] = true }, function(err, parent)
        assert.is_nil(err)
        assert.equals(555, parent.id)
        done()
      end)
    end)
    restore()
  end)

  it("ignores parents on other trackers", function()
    local restore = stub(reverse_routes({
      { id = 42, title = "Single sign-on support", tracker = { id = 8, label = "Epics" } },
    }))
    sync(function(done)
      artifacts.parent_on(1234, { [12] = true }, function(err, parent)
        assert.is_nil(err)
        assert.is_nil(parent)
        done()
      end)
    end)
    restore()
  end)

  it("answers nothing when the artifact has no parent", function()
    local restore = stub(reverse_routes({}))
    sync(function(done)
      artifacts.parent_on(1234, { [12] = true }, function(err, parent)
        assert.is_nil(err)
        assert.is_nil(parent)
        done()
      end)
    end)
    restore()
  end)
end)

describe("milestones.move_content", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("patches the target with `remove_from`, which is Tuleap's own move", function()
    local restore, writes = stub(function(method, path)
      if method == "PATCH" and path == "/milestones/777/content" then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end)
    sync(function(done)
      milestones.move_content(555, 777, { 1234 }, function(err)
        assert.is_nil(err)
        done()
      end)
    end)
    assert.equals(1, #writes)
    assert.same({ { id = 1234, remove_from = 555 } }, writes[1].body.add)
    restore()
  end)

  it("never falls back to PUT, which could leave the artifact planned twice", function()
    local restore, writes = stub(function(method)
      if method == "PATCH" then
        return "HTTP 405: Method Not Allowed"
      end
      return nil, {}
    end)
    sync(function(done)
      milestones.move_content(555, 777, { 1234 }, function(err)
        assert.is_true(err:find("405", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(1, #writes)
    assert.equals("PATCH", writes[1].method)
    restore()
  end)
end)

describe("milestones.tracker_ids", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("collects the trackers the project's milestones live on", function()
    local restore = stub(function(method, path)
      if path == "/projects/102/milestones" then
        return nil, {
          { id = 1, label = "Release 1", artifact = { id = 1, tracker = { id = 11 } } },
          { id = 2, label = "Sprint 59", artifact = { id = 2, tracker = { id = 12 } } },
        }
      elseif path:match("^/milestones/%d+/milestones$") then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end)
    sync(function(done)
      milestones.tracker_ids(102, function(err, ids)
        assert.is_nil(err)
        assert.is_true(ids[11])
        assert.is_true(ids[12])
        assert.is_nil(ids[7])
        done()
      end)
    end)
    restore()
  end)
end)
