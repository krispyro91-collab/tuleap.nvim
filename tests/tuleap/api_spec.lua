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
