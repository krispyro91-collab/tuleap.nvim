local client = require("tuleap.api.client")
local config = require("tuleap.config")
local pickers = require("tuleap.pickers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

--- An artifact assigned to someone else, plus one assigned to the test user.
local function tracker_artifacts()
  local mine = vim.deepcopy(fixtures.artifact)
  local theirs = vim.deepcopy(fixtures.artifact)
  theirs.id, theirs.xref = 999, "bug #999"
  theirs.values[4] = { field_id = 4, label = "Assigned to", type = "msb", bind_value_ids = { 103 } }
  return { mine, theirs }
end

---@param handler fun(path: string, query: table): string?, any
---@return fun() restore, table calls
local function stub(handler)
  local original = client.request
  local calls = {}
  client.request = function(opts, cb)
    calls[#calls + 1] = { path = opts.path, query = opts.query or {} }
    local err, data = handler(opts.path, opts.query or {})
    vim.schedule(function()
      cb(err, data, { status = err and 400 or 200, headers = {} })
    end)
  end
  return function()
    client.request = original
  end, calls
end

---@param fn fun(done: fun())
local function sync(fn)
  local finished = false
  fn(function()
    finished = true
  end)
  assert.is_true(vim.wait(3000, function()
    return finished
  end, 5), "picker never produced a result")
end

--- Run `pickers.mine()` with `pickers.artifacts` captured.
---@param handler fun(path: string, query: table): string?, any
---@return table? opts passed to pickers.artifacts, table calls
local function run_mine(handler)
  local restore, calls = stub(handler)
  local original_artifacts = pickers.artifacts
  local captured
  pickers.artifacts = function(opts)
    captured = opts
  end

  sync(function(done)
    pickers.mine()
    -- `mine` fans out over trackers; poll until it settles.
    local timer = vim.uv.new_timer()
    local ticks = 0
    timer:start(50, 50, function()
      ticks = ticks + 1
      if captured or ticks > 40 then
        timer:stop()
        timer:close()
        vim.schedule(done)
      end
    end)
  end)

  pickers.artifacts = original_artifacts
  restore()
  return captured, calls
end

describe("pickers.mine", function()
  local saved_trackers, saved_project

  before_each(function()
    saved_trackers = config.options.trackers
    saved_project = config.state.project_id
    config.options.trackers = { issue = "bug" }
    config.state.project_id = 101
    require("tuleap.cache").invalidate()
  end)

  after_each(function()
    config.options.trackers = saved_trackers
    config.state.project_id = saved_project
    require("tuleap.cache").invalidate()
  end)

  ---@param artifacts_for fun(query: table): string?, any
  local function routes(artifacts_for)
    return function(path, query)
      if path == "/users/self" then
        return nil, fixtures.user
      elseif path == "/projects/101/trackers" then
        return nil, { { id = 7, label = "Bugs", item_name = "bug" } }
      elseif path == "/trackers/7" then
        return nil, fixtures.tracker
      elseif path == "/trackers/7/artifacts" then
        return artifacts_for(query)
      end
      return "HTTP 404: no stub for " .. path
    end
  end

  it("uses the tracker's own contributor field name in the TQL query", function()
    local _, calls = run_mine(routes(function(query)
      if query.expert_query then
        return nil, { tracker_artifacts()[1] }
      end
      return nil, tracker_artifacts()
    end))

    local queried
    for _, call in ipairs(calls) do
      if call.query.expert_query then
        queried = call.query.expert_query
      end
    end
    -- The fixture tracker names its contributor field `assigned_to`.
    assert.equals("assigned_to = MYSELF()", queried)
  end)

  it("falls back to a client side filter when TQL matches nothing", function()
    local captured, calls = run_mine(routes(function(query)
      if query.expert_query then
        return nil, {} -- accepted by the server, but empty
      end
      return nil, tracker_artifacts()
    end))

    assert.is_not_nil(captured, "the picker was never opened")
    assert.equals(1, #captured.artifacts)
    assert.equals(1234, captured.artifacts[1].id)

    local unfiltered = 0
    for _, call in ipairs(calls) do
      if call.path == "/trackers/7/artifacts" and not call.query.expert_query then
        unfiltered = unfiltered + 1
      end
    end
    assert.is_true(unfiltered > 0, "no fallback request was made")
  end)

  it("falls back when the server rejects the query outright", function()
    local captured = run_mine(routes(function(query)
      if query.expert_query then
        return "HTTP 400: Unknown field assigned_to"
      end
      return nil, tracker_artifacts()
    end))
    assert.is_not_nil(captured)
    assert.equals(1, #captured.artifacts)
  end)

  it("matches bind_value_ids as well as nested user objects", function()
    local captured = run_mine(routes(function(query)
      if query.expert_query then
        return nil, {}
      end
      local bind_shape = vim.deepcopy(fixtures.artifact)
      bind_shape.values[4] =
        { field_id = 4, label = "Assigned to", type = "msb", bind_value_ids = { 102 } }
      return nil, { bind_shape }
    end))
    assert.is_not_nil(captured)
    assert.equals(1, #captured.artifacts)
  end)

  it("does not return the same artifact twice", function()
    local captured = run_mine(routes(function(query)
      if query.expert_query then
        return nil, { tracker_artifacts()[1] }
      end
      return nil, tracker_artifacts()
    end))
    assert.is_not_nil(captured)
    assert.equals(1, #captured.artifacts)
  end)
end)
