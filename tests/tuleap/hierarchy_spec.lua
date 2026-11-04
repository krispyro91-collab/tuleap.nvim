local client = require("tuleap.api.client")
local config = require("tuleap.config")
local hierarchy = require("tuleap.api.hierarchy")

local EPIC_TRACKER, STORY_TRACKER, PROJECT = 8, 9, 101

local release =
  { id = 500, label = "Release 1.2", start_date = "2026-10-01", end_date = "2026-12-31" }
local sprint = { id = 556, label = "Sprint 43", start_date = "2026-11-05", end_date = "2026-11-19" }
local epic = { id = 42, title = "Single sign-on", tracker = { id = EPIC_TRACKER } }

--- An artifact whose reverse links point at `ids`.
---@param id integer
---@param ids integer[]?
local function story(id, ids)
  local links = {}
  for _, link_id in ipairs(ids or {}) do
    links[#links + 1] = { id = link_id, type = "_is_child" }
  end
  return {
    id = id,
    tracker = { id = STORY_TRACKER },
    values = ids and { { field_id = 30, type = "art_link", links = {}, reverse_links = links } }
      or {},
  }
end

describe("hierarchy.resolve", function()
  local original, saved, seen

  ---@param opts {no_epic_tracker: boolean?}?
  local function stub(opts)
    opts = opts or {}
    client.request = function(req, cb)
      seen[#seen + 1] = req.path
      local answer
      if req.path:match("^/projects/%d+/trackers$") then
        answer = opts.no_epic_tracker and {}
          or { { id = EPIC_TRACKER, item_name = "epic", label = "Epics" } }
      elseif req.path:match("^/projects/%d+/milestones$") then
        answer = { release }
      elseif req.path == "/milestones/500/milestones" then
        answer = { sprint }
      elseif req.path == "/trackers/8" then
        answer = { id = EPIC_TRACKER, item_name = "epic", label = "Epics" }
      elseif req.path == "/artifacts/42" then
        answer = epic
      end
      vim.schedule(function()
        if answer == nil then
          return cb("HTTP 404: no stub for " .. req.path)
        end
        cb(nil, answer, { status = 200, headers = {} })
      end)
    end
  end

  ---@param list table[]
  ---@return table<integer, tuleap.Parents>
  local function resolve(list)
    local result
    hierarchy.resolve(list, function(parents)
      result = parents
    end)
    assert.is_true(
      vim.wait(2000, function()
        return result ~= nil
      end, 5),
      "resolve never answered"
    )
    return result
  end

  ---@param path string
  ---@return integer
  local function count(path)
    return #vim.tbl_filter(function(p)
      return p == path
    end, seen)
  end

  before_each(function()
    require("tuleap.cache").invalidate()
    original = client.request
    saved = { project_id = config.state.project_id, epic = config.options.trackers.epic }
    config.state.project_id = PROJECT
    config.options.trackers.epic = "epic"
    seen = {}
  end)

  after_each(function()
    client.request = original
    config.state.project_id = saved.project_id
    config.options.trackers.epic = saved.epic
    require("tuleap.cache").invalidate()
  end)

  it("finds the sprint without reading any artifact", function()
    stub()
    local parents = resolve({ story(1, { 556 }) })
    assert.equals("Sprint 43", parents[1].sprint.label)
    assert.is_nil(parents[1].epic)
    assert.equals(0, count("/artifacts/556"))
  end)

  it("reads a shared epic only once", function()
    stub()
    local parents = resolve({ story(1, { 42 }), story(2, { 42, 556 }), story(3, { 42 }) })
    assert.equals("Single sign-on", parents[1].epic.title)
    assert.equals("Single sign-on", parents[3].epic.title)
    assert.equals("Sprint 43", parents[2].sprint.label)
    assert.equals(1, count("/artifacts/42"))
  end)

  it("prefers the sprint over the release above it", function()
    stub()
    local parents = resolve({ story(1, { 500, 556 }), story(2, { 556, 500 }) })
    assert.equals("Sprint 43", parents[1].sprint.label)
    assert.equals("Sprint 43", parents[2].sprint.label)
  end)

  it("leaves out an artifact without reverse links", function()
    stub()
    local parents = resolve({ story(1) })
    assert.is_nil(parents[1])
  end)

  it("reads incoming cross references on trackers without a link field", function()
    stub()
    local issue = {
      id = 25,
      xref = "issue #25",
      tracker = { id = STORY_TRACKER },
      values = {
        {
          field_id = 31,
          type = "cross",
          label = "References",
          value = {
            { ref = "sprint #556", direction = "in" },
            { ref = "epic #42", direction = "in" },
            { ref = "issue #77", direction = "in" },
            { ref = "bug #88", direction = "out" },
          },
        },
      },
    }
    local parents = resolve({ issue })
    assert.equals("Sprint 43", parents[25].sprint.label)
    assert.equals("Single sign-on", parents[25].epic.title)
    assert.equals(0, count("/artifacts/77"))
    assert.equals(0, count("/artifacts/88"))
  end)

  it("still finds sprints when the epic tracker cannot be resolved", function()
    stub({ no_epic_tracker = true })
    local parents = resolve({ story(1, { 42, 556 }) })
    assert.equals("Sprint 43", parents[1].sprint.label)
    assert.is_nil(parents[1].epic)
    assert.equals(0, count("/artifacts/42"))
  end)
end)

describe("hierarchy.references", function()
  it("parses each reference into its keyword and artifact id", function()
    local refs = hierarchy.references({
      values = {
        {
          type = "cross",
          value = { { ref = "af_sprint #1", direction = "in" }, { ref = "wiki:Home" } },
        },
      },
    })
    assert.same({ { id = 1, key = "af_sprint", ref = "af_sprint #1", direction = "in" } }, refs)
  end)
end)
