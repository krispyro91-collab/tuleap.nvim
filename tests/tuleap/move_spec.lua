-- Attaching an artifact that already hangs somewhere must *move* it.
--
-- The two halves are deliberately different: a sprint is moved with Tuleap's
-- own `add: [{id, remove_from}]` PATCH, while an epic is moved by rewriting
-- the artifact link field of both parents, because that is the only generic
-- way to do it. Both are driven here through `actions`, since the behaviour
-- being asserted is the sequence of writes, not any single request.

local actions = require("tuleap.actions")
local client = require("tuleap.api.client")
local config = require("tuleap.config")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

---@param handler fun(method: string, path: string, body: table?): string?, any
---@return fun() restore, table writes, table notices
local function stub(handler)
  local original_request, original_notify = client.request, vim.notify
  local writes, notices = {}, {}

  client.request = function(opts, cb)
    local method = (opts.method or "GET"):upper()
    if method ~= "GET" then
      writes[#writes + 1] = {
        method = method,
        path = opts.path,
        body = type(opts.body) == "table" and opts.body or nil,
      }
    end
    local err, data = handler(method, opts.path, opts.body)
    vim.schedule(function()
      cb(err, data, { status = err and 400 or 200, headers = {} })
    end)
  end

  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = msg, level = level }
  end

  return function()
    client.request = original_request
    vim.notify = original_notify
  end, writes, notices
end

---@param notices table
---@return string
local function joined(notices)
  local parts = {}
  for _, notice in ipairs(notices) do
    parts[#parts + 1] = notice.msg
  end
  return table.concat(parts, "\n")
end

--- Wait for `writes` to stop growing, then a little longer: these flows chain
--- several requests and there is no single callback to hook onto.
---@param writes table
---@param expected integer
local function settle(writes, expected)
  assert.is_true(
    vim.wait(3000, function()
      return #writes >= expected
    end, 10),
    ("only %d of %d writes happened"):format(#writes, expected)
  )
  vim.wait(200, function()
    return false
  end)
end

---@param writes table
---@param method string
---@param path string
---@return table?
local function write_to(writes, method, path)
  for _, write in ipairs(writes) do
    if write.method == method and write.path == path then
      return write
    end
  end
  return nil
end

describe("actions.attach_to_epic", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  --- Artifact 1234 hangs under epic #99; epic #42 is the new parent.
  ---@param reverse table[] reverse links of the artifact
  local function routes(reverse)
    local epic_99 = {
      id = 99,
      xref = "epic #99",
      title = "Former home",
      tracker = { id = 8, label = "Epics" },
      values = {
        {
          field_id = 22,
          label = "Links",
          type = "art_link",
          links = { { id = 1234, type = "_is_child" }, { id = 555, type = "_is_child" } },
        },
      },
    }
    return function(method, path)
      if path == "/artifacts/42" then
        return nil, fixtures.epic
      elseif path == "/artifacts/99" then
        return nil, epic_99
      elseif path == "/artifacts/1234" then
        return nil, { id = 1234, xref = "bug #1234", tracker = { id = 7 }, values = {} }
      elseif path == "/artifacts/1234/linked_artifacts" then
        return nil, { collection = reverse }
      elseif path == "/trackers/8" then
        return nil, fixtures.epic_tracker
      elseif method == "PUT" then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end
  end

  it("links the new epic and unlinks the old one", function()
    local restore, writes, notices = stub(routes({
      { id = 99, xref = "epic #99", title = "Former home", tracker = { id = 8, label = "Epics" } },
    }))

    actions.attach_to_epic(1234, { parent_id = 42 })
    settle(writes, 2)

    local attached = write_to(writes, "PUT", "/artifacts/42")
    local detached = write_to(writes, "PUT", "/artifacts/99")
    assert.is_not_nil(attached, "the new parent was not written")
    assert.is_not_nil(detached, "the old parent was not written")

    -- The new parent keeps its own children and gains ours.
    local gained = {}
    for _, link in ipairs(attached.body.values[1].links) do
      gained[#gained + 1] = link.id
    end
    assert.same({ 777, 888, 1234 }, gained)

    -- The old parent keeps everything except ours.
    assert.same({ { id = 555, type = "_is_child" } }, detached.body.values[1].links)

    assert.is_true(joined(notices):find("moved from epic #99", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("attaches without detaching when the epic is the only parent on that tracker", function()
    -- The sprint is a parent too, on tracker 12; attaching to an epic must
    -- leave the artifact planned where it is.
    local restore, writes, notices = stub(routes({
      { id = 555, xref = "sprint #555", title = "Sprint 59", tracker = { id = 12, label = "Sprints" } },
    }))

    actions.attach_to_epic(1234, { parent_id = 42 })
    settle(writes, 1)

    assert.is_not_nil(write_to(writes, "PUT", "/artifacts/42"))
    assert.equals(1, #writes, "nothing else may be rewritten")
    assert.is_true(joined(notices):find("attached to", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("says so when the new link took but the old one could not be dropped", function()
    local restore, writes, notices = stub(function(method, path, body)
      if method == "PUT" and path == "/artifacts/99" then
        return "HTTP 403: forbidden"
      end
      return routes({
        { id = 99, xref = "epic #99", title = "Former home", tracker = { id = 8, label = "Epics" } },
      })(method, path, body)
    end)

    actions.attach_to_epic(1234, { parent_id = 42 })
    settle(writes, 2)

    local text = joined(notices)
    assert.is_true(text:find("is now under", 1, true) ~= nil, text)
    assert.is_true(text:find("epic #99", 1, true) ~= nil, text)
    restore()
  end)
end)

describe("actions.attach_to_sprint", function()
  local previous_project

  before_each(function()
    require("tuleap.cache").invalidate()
    previous_project = config.state.project_id
    config.state.project_id = 102
  end)

  after_each(function()
    config.state.project_id = previous_project
  end)

  --- Sprint #555 and release #11 exist; #777 is the sprint being planned into.
  ---@param reverse table[]
  local function routes(reverse)
    return function(method, path)
      if path == "/projects/102/milestones" then
        return nil, {
          { id = 11, label = "Release 1", artifact = { id = 11, tracker = { id = 11 } } },
          { id = 555, label = "Sprint 59", artifact = { id = 555, tracker = { id = 12 } } },
          { id = 777, label = "Sprint 64", artifact = { id = 777, tracker = { id = 12 } } },
        }
      elseif path:match("^/milestones/%d+/milestones$") then
        return nil, {}
      elseif path == "/artifacts/1234" then
        return nil, { id = 1234, xref = "bug #1234", tracker = { id = 7 }, values = {} }
      elseif path == "/artifacts/1234/linked_artifacts" then
        return nil, { collection = reverse }
      elseif method == "PATCH" then
        return nil, {}
      end
      return "HTTP 404: no stub for " .. method .. " " .. path
    end
  end

  it("moves the artifact out of the sprint that holds it", function()
    local restore, writes, notices = stub(routes({
      { id = 555, xref = "sprint #555", title = "Sprint 59", tracker = { id = 12, label = "Sprints" } },
    }))

    actions.attach_to_sprint(1234, { milestone_id = 777 })
    settle(writes, 1)

    assert.equals(1, #writes)
    assert.equals("PATCH", writes[1].method)
    assert.equals("/milestones/777/content", writes[1].path)
    assert.same({ { id = 1234, remove_from = 555 } }, writes[1].body.add)
    assert.is_true(joined(notices):find("moved to", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("moves it out of a release too, not just a sprint of the same tracker", function()
    local restore, writes = stub(routes({
      { id = 11, xref = "release #11", title = "Release 1", tracker = { id = 11, label = "Releases" } },
    }))

    actions.attach_to_sprint(1234, { milestone_id = 777 })
    settle(writes, 1)

    assert.same({ { id = 1234, remove_from = 11 } }, writes[1].body.add)
    restore()
  end)

  it("just adds when the artifact is planned nowhere", function()
    local restore, writes, notices = stub(routes({}))

    actions.attach_to_sprint(1234, { milestone_id = 777 })
    settle(writes, 1)

    assert.same({ { id = 1234 } }, writes[1].body.add)
    assert.is_true(joined(notices):find("planned in", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("leaves the epic above it alone", function()
    local restore, writes = stub(routes({
      { id = 42, xref = "epic #42", title = "Single sign-on", tracker = { id = 8, label = "Epics" } },
    }))

    actions.attach_to_sprint(1234, { milestone_id = 777 })
    settle(writes, 1)

    -- The epic is not a milestone tracker, so nothing is detached.
    assert.same({ { id = 1234 } }, writes[1].body.add)
    assert.equals(1, #writes)
    restore()
  end)

  it("adds without detaching when the milestone trackers cannot be listed", function()
    local restore, writes = stub(function(method, path, body)
      if path == "/projects/102/milestones" then
        return "HTTP 403: forbidden"
      end
      return routes({})(method, path, body)
    end)

    actions.attach_to_sprint(1234, { milestone_id = 777 })
    settle(writes, 1)

    assert.same({ { id = 1234 } }, writes[1].body.add)
    restore()
  end)
end)
