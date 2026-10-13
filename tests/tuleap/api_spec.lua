local artifacts = require("tuleap.api.artifacts")
local client = require("tuleap.api.client")
local config = require("tuleap.config")
local trackers = require("tuleap.api.trackers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

describe("client.url", function()
  it("prefixes the API version", function()
    assert.equals("https://tuleap.example.test/api/v1/artifacts/5", client.url("/artifacts/5"))
  end)

  it("leaves an explicit /api path alone", function()
    assert.equals("https://tuleap.example.test/api/v1/projects", client.url("/api/v1/projects"))
  end)

  it("encodes query parameters deterministically", function()
    local url = client.url("/trackers/7/artifacts", { values = "all", limit = 10 })
    assert.equals("https://tuleap.example.test/api/v1/trackers/7/artifacts?limit=10&values=all", url)
  end)

  it("JSON-encodes table parameters", function()
    local url = client.url("/projects", { query = { is_member_of = true } })
    assert.is_true(url:find("query=", 1, true) ~= nil)
    assert.is_nil(url:find("{", 1, true), "braces must be percent-encoded")
  end)
end)

describe("config", function()
  it("normalises the instance URL", function()
    local previous = config.options.url
    for _, input in ipairs({
      "https://host",
      "https://host/",
      "https://host/api",
      "https://host/api/v1/",
    }) do
      config.options.url = input
      assert.equals("https://host", config.url(), "failed for " .. input)
    end
    config.options.url = previous
  end)

  it("uses only the first key when the secret holds two concatenated", function()
    local key = "tlp-k1-11.aaaaaaaaaaaaaaaa"
    local previous = config.options.token
    config.forget_token()
    config.options.token = key .. "tlp-k1-22.bbbbbbbbbbbbbbbb"
    assert.equals(key, config.token())
    config.options.token = previous
    config.forget_token()
  end)

  it("leaves a single key untouched", function()
    local key = "tlp-k1-11.aaaaaaaaaaaaaaaa"
    local previous = config.options.token
    config.forget_token()
    config.options.token = key
    assert.equals(key, config.token())
    config.options.token = previous
    config.forget_token()
  end)

  it("reports what is missing", function()
    local previous = config.options.url
    config.options.url = nil
    local saved_env = vim.env[config.options.env.url]
    vim.env[config.options.env.url] = nil
    local ok, err = config.validate()
    assert.is_false(ok)
    assert.is_true(err:find("URL", 1, true) ~= nil)
    vim.env[config.options.env.url] = saved_env
    config.options.url = previous
  end)
end)

describe("trackers", function()
  it("finds fields by name, label and id", function()
    assert.equals(1, trackers.field(fixtures.tracker, "summary").field_id)
    assert.equals(1, trackers.field(fixtures.tracker, "Summary").field_id)
    assert.equals(1, trackers.field(fixtures.tracker, 1).field_id)
    assert.is_nil(trackers.field(fixtures.tracker, "nope"))
  end)

  it("resolves semantics", function()
    assert.equals("Status", trackers.semantic_field(fixtures.tracker, "status").label)
    assert.equals("Assigned to", trackers.semantic_field(fixtures.tracker, "contributor").label)
  end)

  it("splits open and closed status values", function()
    local closed = trackers.closed_values(fixtures.tracker)
    assert.equals(2, #closed)
    assert.equals("Fixed", closed[1].label)
    assert.equals("Won't fix", closed[2].label)
  end)

  it("guesses the effort field", function()
    assert.equals("Remaining effort", trackers.effort_field(fixtures.tracker).label)
  end)

  it("builds REST payloads per field type", function()
    local status = trackers.field(fixtures.tracker, "status")
    assert.same({ field_id = 3, bind_value_ids = { 303 } }, trackers.value_payload(status, 303))
    assert.same(
      { field_id = 2, value = { content = "hi", format = "text" } },
      trackers.value_payload(trackers.field(fixtures.tracker, "details"), "hi")
    )
    assert.same(
      { field_id = 1, value = "title" },
      trackers.value_payload(trackers.field(fixtures.tracker, "summary"), "title")
    )
    assert.same(
      { field_id = 5, value = 4.5 },
      trackers.value_payload(trackers.field(fixtures.tracker, "remaining_effort"), "4.5")
    )
  end)

  it("renders cross reference lists", function()
    -- `cross` fields carry an array of {ref, url} under `value`.
    assert.equals(
      "art #12, art #34",
      trackers.render_value({
        field_id = 9,
        type = "cross",
        value = { { ref = "art #12", url = "/x" }, { ref = "art #34", url = "/y" } },
      })
    )
  end)

  it("renders values of every shape", function()
    assert.equals("SSO redirect loops on first login", trackers.render_value(fixtures.artifact.values[1]))
    assert.equals("In progress", trackers.render_value(fixtures.artifact.values[3]))
    assert.equals("Alice Martin (alice)", trackers.render_value(fixtures.artifact.values[4]))
    assert.equals("3", trackers.render_value(fixtures.artifact.values[5]))
  end)

  it("only offers writable, editable fields", function()
    local editable = trackers.editable_fields(fixtures.tracker)
    assert.equals(6, #editable)
    local required = trackers.editable_fields(fixtures.tracker, { required_only = true })
    assert.equals(2, #required)
  end)
end)

describe("artifacts", function()
  it("reads titles, xrefs and status", function()
    assert.equals("SSO redirect loops on first login", artifacts.title(fixtures.artifact))
    assert.equals("bug #1234", artifacts.xref(fixtures.artifact))
    assert.equals("In progress", artifacts.status(fixtures.artifact))
  end)

  it("trusts is_open when present and guesses otherwise", function()
    assert.is_true(artifacts.is_open(fixtures.artifact))
    assert.is_true(artifacts.is_open({ status = "In progress" }))
    assert.is_false(artifacts.is_open({ status = "Closed" }))
    assert.is_false(artifacts.is_open({ status = "Fixed" }))
    assert.is_true(artifacts.is_open({}))
  end)

  it("builds absolute browser URLs", function()
    assert.equals("https://tuleap.example.test/plugins/tracker/?aid=1234", artifacts.url(fixtures.artifact))
    assert.equals("https://tuleap.example.test/plugins/tracker/?aid=9", artifacts.url(9))
  end)
end)

describe("client pagination limits", function()
  --- Record every request and answer from `responder`.
  ---@param responder fun(opts: table): string?, any
  ---@return table[] seen, fun() restore
  local function spy(responder)
    local original = client.request
    local seen = {}
    client.request = function(opts, cb)
      seen[#seen + 1] = vim.deepcopy(opts)
      local err, data, meta = responder(opts)
      vim.schedule(function()
        cb(err, data, meta)
      end)
    end
    return seen, function()
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
    end, 5), "callback never fired")
  end

  it("caps /projects at 50 before the first request", function()
    assert.equals(50, client.limit_cap("/projects"))
    local seen, restore = spy(function()
      return nil, {}, { status = 200, headers = {} }
    end)
    sync(function(done)
      client.paginate("/projects", nil, function(err)
        assert.is_nil(err)
        done()
      end)
    end)
    assert.equals(50, seen[1].query.limit)
    restore()
  end)

  it("learns the cap from Tuleap's error and replays the page", function()
    local path = "/trackers/7/artifacts"
    local page = {}
    for index = 1, 50 do
      page[index] = { id = index }
    end

    local seen, restore = spy(function(opts)
      if opts.query.limit > 50 then
        return "HTTP 400: Bad Request: Invalid value specified for `limit`."
          .. " Maximum allowed value is 50."
      end
      -- One full page, then a short one so pagination stops.
      return nil, opts.query.offset == 0 and page or { { id = 51 } }, { status = 200, headers = {} }
    end)

    sync(function(done)
      client.paginate(path, nil, function(err, items)
        assert.is_nil(err)
        -- The rejected attempt must not lose or duplicate any artifact.
        assert.equals(51, #items)
        done()
      end)
    end)

    assert.equals(100, seen[1].query.limit, "first attempt uses the configured per_page")
    assert.equals(50, seen[2].query.limit, "retry uses the advertised maximum")
    assert.equals(0, seen[2].query.offset, "the rejected page is replayed, not skipped")
    assert.equals(50, seen[3].query.offset, "the next page follows the reduced window")
    assert.equals(50, client.limit_cap(path))
    restore()
  end)

  it("remembers the cap for the next call on that route", function()
    local seen, restore = spy(function()
      return nil, {}, { status = 200, headers = {} }
    end)
    sync(function(done)
      -- A different tracker id: the cap is keyed on the route shape.
      client.paginate("/trackers/42/artifacts", nil, function()
        done()
      end)
    end)
    assert.equals(50, seen[1].query.limit)
    restore()
  end)

  it("gives up on a genuine error instead of looping", function()
    local seen, restore = spy(function()
      return "HTTP 403: you are not a member of this project"
    end)
    sync(function(done)
      client.paginate("/trackers/99/artifacts", nil, function(err)
        assert.is_true(err:find("403", 1, true) ~= nil)
        done()
      end)
    end)
    assert.equals(1, #seen)
    restore()
  end)
end)
