-- Adding and removing one involved user.
--
-- Tuleap writes a list field as a *whole list*, so every assertion here is
-- about what the single PUT carries: the user that was asked for, plus the
-- ones that were already there and must survive the round trip.

local actions = require("tuleap.actions")
local client = require("tuleap.api.client")
local config = require("tuleap.config")
local trackers = require("tuleap.api.trackers")

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

--- Wait for the flow to reach `expected` writes, then let the notification land.
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

--- Nothing must be written; give the flow time to prove it.
---@param writes table
local function settle_quiet(writes)
  vim.wait(500, function()
    return #writes > 0
  end, 10)
  assert.equals(0, #writes, "the artifact was written when it should not have been")
end

--- The bug artifact, with `involved` as the ids on its "Involved users" field.
---@param involved integer[]?
---@return table
local function artifact_with(involved)
  local artifact = vim.deepcopy(fixtures.artifact)
  for _, value in ipairs(artifact.values) do
    if value.field_id == 7 then
      value.values = nil
      value.bind_value_ids = involved
    end
  end
  return artifact
end

---@param artifact table
---@return fun(method: string, path: string): string?, any
local function routes(artifact)
  return function(method, path)
    if path == "/artifacts/1234" then
      return nil, artifact
    elseif path == "/trackers/7" then
      return nil, fixtures.tracker
    elseif method == "PUT" then
      return nil, {}
    end
    return "HTTP 404: no stub for " .. method .. " " .. path
  end
end

---@param write table?
---@return integer[]
local function written_ids(write)
  assert.is_not_nil(write, "no write to read ids from")
  assert.equals(1, #write.body.values, "only the involved-users field may be written")
  assert.equals(7, write.body.values[1].field_id)
  return write.body.values[1].bind_value_ids
end

describe("actions.involve", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("adds the user to the ones already involved", function()
    local restore, writes, notices = stub(routes(artifact_with({ 103 })))

    actions.involve(1234, { user_id = 104 })
    settle(writes, 1)

    assert.equals("PUT", writes[1].method)
    assert.equals("/artifacts/1234", writes[1].path)
    assert.same({ 103, 104 }, written_ids(writes[1]))
    -- No follow-up comment: this is a field edit, not a discussion.
    assert.is_nil(writes[1].body.comment)
    local text = joined(notices)
    assert.is_true(text:find("Carol Nguyen (carol) added", 1, true) ~= nil, text)
    restore()
  end)

  it("drops Tuleap's None value instead of sending it back", function()
    -- An empty list field reads as `{ 100 }` on many instances; keeping it
    -- would send "None and Carol", which Tuleap rejects.
    local restore, writes = stub(routes(artifact_with({ trackers.NONE_VALUE_ID })))

    actions.involve(1234, { user_id = 104 })
    settle(writes, 1)

    assert.same({ 104 }, written_ids(writes[1]))
    restore()
  end)

  it("offers everyone but those already involved", function()
    local restore, writes = stub(routes(artifact_with({ 103 })))
    local original, offered = vim.ui.select, nil

    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      cb(items[1])
    end
    actions.involve(1234)
    settle(writes, 1)
    vim.ui.select = original

    assert.same({ "Alice Martin (alice)", "Carol Nguyen (carol)" }, offered)
    assert.same({ 103, 102 }, written_ids(writes[1]))
    restore()
  end)

  it("says so rather than write when nobody is left to add", function()
    local restore, writes, notices = stub(routes(artifact_with({ 102, 103, 104 })))

    actions.involve(1234, { user_id = 104 })
    settle_quiet(writes)

    assert.is_true(joined(notices):find("already lists everyone", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("re-reads the artifact instead of trusting the cache", function()
    -- The list is written whole, so a cached read would resurrect anybody
    -- removed since — or drop whoever was added elsewhere, as here.
    local current = artifact_with({ 103 })
    local restore, writes = stub(function(method, path, body)
      return routes(current)(method, path, body)
    end)

    local primed = false
    require("tuleap.api.artifacts").get(1234, function()
      primed = true
    end)
    vim.wait(2000, function()
      return primed
    end, 10)

    current = artifact_with({ 103, 104 })
    actions.involve(1234, { user_id = 102 })
    settle(writes, 1)

    assert.same({ 103, 104, 102 }, written_ids(writes[1]))
    restore()
  end)

  it("refuses to write a field the artifact does not expose", function()
    -- A field missing from the payload is Tuleap saying "you may not read
    -- this one"; writing the list then means wiping it.
    local artifact = artifact_with(nil)
    artifact.values = vim.tbl_filter(function(value)
      return value.field_id ~= 7
    end, artifact.values)
    local restore, writes, notices = stub(routes(artifact))

    actions.involve(1234, { user_id = 104 })
    settle_quiet(writes)

    assert.is_true(joined(notices):find("is not readable", 1, true) ~= nil, joined(notices))
    restore()
  end)

  it("names the tracker's list fields when no involved field matches", function()
    local previous = config.options.fields.involved
    config.options.fields.involved = "nothing_like_that"
    local restore, writes, notices = stub(routes(artifact_with({ 103 })))

    actions.involve(1234, { user_id = 104 })
    settle_quiet(writes)

    local text = joined(notices)
    assert.is_true(text:find("fields.involved", 1, true) ~= nil, text)
    assert.is_true(text:find("Involved users (involved_users)", 1, true) ~= nil, text)
    config.options.fields.involved = previous
    restore()
  end)
end)

describe("actions.uninvolve", function()
  before_each(function()
    require("tuleap.cache").invalidate()
  end)

  it("removes only the user asked for", function()
    local restore, writes, notices = stub(routes(artifact_with({ 102, 103, 104 })))

    actions.uninvolve(1234, { user_id = 103 })
    settle(writes, 1)

    assert.same({ 102, 104 }, written_ids(writes[1]))
    local text = joined(notices)
    assert.is_true(text:find("Bob Dupont (bob) removed", 1, true) ~= nil, text)
    restore()
  end)

  it("clears the field when the last one goes", function()
    local restore, writes = stub(routes(artifact_with({ 103 })))

    actions.uninvolve(1234, { user_id = 103 })
    settle(writes, 1)

    assert.same({}, written_ids(writes[1]))
    restore()
  end)

  it("only offers the users actually on the artifact", function()
    local restore, writes = stub(routes(artifact_with({ 104 })))
    local original, offered = vim.ui.select, nil

    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      cb(items[1])
    end
    actions.uninvolve(1234)
    settle(writes, 1)
    vim.ui.select = original

    assert.same({ "Carol Nguyen (carol)" }, offered)
    assert.same({}, written_ids(writes[1]))
    restore()
  end)

  it("says so rather than write when nobody is involved", function()
    local restore, writes, notices = stub(routes(artifact_with({})))

    actions.uninvolve(1234, { user_id = 103 })
    settle_quiet(writes)

    assert.is_true(joined(notices):find("Nobody is listed", 1, true) ~= nil, joined(notices))
    restore()
  end)
end)

describe("trackers.involved_field", function()
  ---@param fields table[]
  ---@return table
  local function tracker(fields)
    return { id = 1, label = "Bugs", fields = fields }
  end

  it("finds the configured field on the fixture tracker", function()
    assert.equals(7, trackers.involved_field(fixtures.tracker).field_id)
  end)

  it("matches the label as well as the name, ignoring case and plurals", function()
    local found = trackers.involved_field(tracker({
      { field_id = 3, name = "field_42", label = "Involved User", type = "cb" },
    }))
    assert.equals(3, found.field_id)
  end)

  it("ignores a field of the same name that is not a list", function()
    -- Writing bind value ids into a text field would replace its content.
    assert.is_nil(trackers.involved_field(tracker({
      { field_id = 3, name = "involved_users", label = "Involved users", type = "text" },
    })))
  end)

  it("takes a field id or an explicit name from the config", function()
    local previous = config.options.fields.involved
    local fields = {
      { field_id = 9, name = "cc", label = "CC list", type = "msb" },
      { field_id = 3, name = "involved_users", label = "Involved users", type = "msb" },
    }

    config.options.fields.involved = 9
    assert.equals(9, trackers.involved_field(tracker(fields)).field_id)

    config.options.fields.involved = "cc"
    assert.equals(9, trackers.involved_field(tracker(fields)).field_id)

    config.options.fields.involved = false
    assert.is_nil(trackers.involved_field(tracker(fields)))

    config.options.fields.involved = previous
  end)

  it("is nil when the tracker has no such field", function()
    assert.is_nil(trackers.involved_field(tracker({
      { field_id = 3, name = "status", label = "Status", type = "sb" },
    })))
  end)
end)
