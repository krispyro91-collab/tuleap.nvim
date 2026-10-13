local client = require("tuleap.api.client")
local config = require("tuleap.config")
local trackers = require("tuleap.api.trackers")

--- The tracker set of a real instance, with its real shortnames: note that
--- the issue tracker is `af_issue` while the bug tracker's shortname is
--- exactly "bug", so candidate order has to beat match quality.
local SEVEN = {
  { id = 8, label = "Bugs", item_name = "bug" },
  { id = 9, label = "Epics", item_name = "af_epic" },
  { id = 10, label = "Issues", item_name = "af_issue" },
  { id = 11, label = "Releases", item_name = "rel" },
  { id = 12, label = "Sprints", item_name = "af_sprint" },
  { id = 13, label = "Tasks", item_name = "task" },
  { id = 14, label = "User Stories", item_name = "story" },
}

--- Tuleap's Scrum template, which has no "Issues" tracker at all.
local SCRUM = {
  { id = 20, label = "Bugs", item_name = "bug" },
  { id = 21, label = "Epics", item_name = "epic" },
  { id = 22, label = "Sprints", item_name = "sprint" },
  { id = 23, label = "User Stories", item_name = "story" },
}

---@param list table[]
---@return fun() restore
local function serve(list)
  local original = client.request
  client.request = function(_, cb)
    vim.schedule(function()
      cb(nil, list, { status = 200, headers = {} })
    end)
  end
  return function()
    client.request = original
  end
end

---@param key string
---@return integer? id, string? err
local function resolve(key)
  local done, result = false, {}
  trackers.resolve(key, function(err, id)
    result = { err = err, id = id }
    done = true
  end)
  assert.is_true(vim.wait(2000, function()
    return done
  end, 5), "resolve never answered")
  return result.id, result.err
end

describe("trackers.resolve", function()
  local saved_trackers, saved_project

  before_each(function()
    saved_trackers, saved_project = config.options.trackers, config.state.project_id
    config.state.project_id = 102
    require("tuleap.cache").invalidate()
  end)

  after_each(function()
    config.options.trackers, config.state.project_id = saved_trackers, saved_project
    require("tuleap.cache").invalidate()
  end)

  it("matches across plurals, case and punctuation", function()
    local restore = serve(SEVEN)
    config.options.trackers = {}
    -- "story" must reach a tracker labelled "User Stories".
    assert.equals(14, resolve("story"))
    assert.equals(14, resolve("User Stories"))
    assert.equals(14, resolve("user-stories"))
    assert.equals(8, resolve("bug"))
    assert.equals(8, resolve("Bugs"))
    assert.equals(11, resolve("release"))
    restore()
  end)

  it("prefers the first candidate that exists, even over a better later match", function()
    local restore = serve(SEVEN)
    config.options.trackers = { issue = { "issue", "bug" } }
    -- "bug" is an exact shortname hit on tracker 8, while "issue" only matches
    -- tracker 10 through its label. Candidate order must still win.
    assert.equals(10, resolve("issue"))
    restore()
  end)

  it("resolves every default key against a real tracker set", function()
    local restore = serve(SEVEN)
    config.options.trackers = config.defaults.trackers
    assert.equals(10, resolve("issue"))
    assert.equals(9, resolve("epic"))
    assert.equals(14, resolve("story"))
    assert.equals(13, resolve("task"))
    assert.equals(12, resolve("sprint"))
    assert.equals(11, resolve("release"))
    restore()
  end)

  it("falls back to a later candidate when the first is absent", function()
    local restore = serve(SCRUM)
    config.options.trackers = { issue = { "issue", "bug" } }
    -- No "Issues" tracker in the Scrum template: fall back to Bugs.
    assert.equals(20, resolve("issue"))
    restore()
  end)

  it("accepts ids and numeric strings without touching the API", function()
    local restore = serve({})
    config.options.trackers = { issue = 42, epic = "77" }
    assert.equals(42, resolve("issue"))
    assert.equals(77, resolve("epic"))
    restore()
  end)

  it("lists the available trackers when nothing matches", function()
    local restore = serve(SEVEN)
    config.options.trackers = { widget = "widget" }
    local id, err = resolve("widget")
    assert.is_nil(id)
    assert.is_true(err:find("User Stories", 1, true) ~= nil, "error should name real trackers")
    assert.is_true(err:find("trackers.widget", 1, true) ~= nil, "error should name the key to fix")
    restore()
  end)

  it("does not match on a fragment shorter than three characters", function()
    local restore = serve(SEVEN)
    config.options.trackers = {}
    assert.is_nil(resolve("ug"))
    restore()
  end)
end)

describe("trackers.status semantics", function()
  local field = {
    field_id = 3,
    type = "sb",
    label = "Status",
    values = { { id = 301, label = "New" }, { id = 302, label = "Done" } },
  }

  it("reads the open values and splits off the closed ones", function()
    local tracker = { fields = { field }, semantics = { status = { field_id = 3, open_values = { 301 } } } }
    local closed, _, unknown = trackers.closed_values(tracker)
    assert.is_false(unknown)
    assert.equals(1, #closed)
    assert.equals("Done", closed[1].label)
  end)

  it("reads `value_ids`, which is what current Tuleap sends", function()
    local tracker = { fields = { field }, semantics = { status = { field_id = 3, value_ids = { 301 } } } }
    local _, ids, source = trackers.status(tracker)
    assert.same({ 301 }, ids)
    assert.equals("value_ids", source)
    local closed, _, unknown = trackers.closed_values(tracker)
    assert.is_false(unknown)
    assert.equals(1, #closed)
    assert.equals("Done", closed[1].label)
  end)

  it("accepts the alternative key names Tuleap has used", function()
    local tracker = { fields = { field }, semantics = { status = { field_id = 3, open_value_ids = { 301 } } } }
    local _, ids, source = trackers.status(tracker)
    assert.same({ 301 }, ids)
    assert.equals("open_value_ids", source)
  end)

  it("unwraps value objects as well as bare ids", function()
    local tracker =
      { fields = { field }, semantics = { status = { field_id = 3, open_values = { { id = 301 } } } } }
    local _, ids = trackers.status(tracker)
    assert.same({ 301 }, ids)
  end)

  it("reports unknown rather than calling every status closed", function()
    local tracker = { fields = { field }, semantics = { status = { field_id = 3 } } }
    local closed, _, unknown = trackers.closed_values(tracker)
    -- This is the regression: with no open values published, treating the
    -- difference as "closed" made "New" a way to close an artifact.
    assert.is_true(unknown)
    assert.equals(2, #closed)
  end)
end)
