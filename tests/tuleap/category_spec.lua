-- The category field: found by name, offered in the "common" forms.

local actions = require("tuleap.actions")
local client = require("tuleap.api.client")
local config = require("tuleap.config")
local form = require("tuleap.ui.form")
local trackers = require("tuleap.api.trackers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

--- Run `start` with the transport and the form stubbed, and return the ids of
--- the fields the form was opened with.
---@param start fun()
---@return integer[]
local function form_field_ids(start)
  local original_request, original_open = client.request, form.open
  local opened
  client.request = function(opts, cb)
    local data = ({ ["/artifacts/1234"] = fixtures.artifact, ["/trackers/7"] = fixtures.tracker })[opts.path]
    vim.schedule(function()
      cb(not data and ("HTTP 404: no stub for " .. opts.path) or nil, data, { status = 200, headers = {} })
    end)
  end
  form.open = function(spec)
    opened = spec
  end

  start()
  vim.wait(2000, function()
    return opened ~= nil
  end, 10)
  client.request, form.open = original_request, original_open

  assert.is_not_nil(opened, "the form was never opened")
  return vim.tbl_map(function(field)
    return field.field_id
  end, opened.fields)
end

describe("trackers.category_field", function()
  ---@param fields table[]
  ---@return table
  local function tracker(fields)
    return { id = 1, label = "Bugs", fields = fields }
  end

  it("finds the configured field on the fixture tracker", function()
    assert.equals(8, trackers.category_field(fixtures.tracker).field_id)
  end)

  it("matches the label as well as the name, ignoring case and plurals", function()
    local found = trackers.category_field(tracker({
      { field_id = 3, name = "field_42", label = "Categories", type = "msb" },
    }))
    assert.equals(3, found.field_id)
  end)

  it("accepts a field that is not a list", function()
    local found = trackers.category_field(tracker({
      { field_id = 3, name = "category", label = "Category", type = "string" },
    }))
    assert.equals(3, found.field_id)
  end)

  it("takes a field id or an explicit name from the config", function()
    local previous = config.options.fields.category
    local fields = {
      { field_id = 9, name = "component", label = "Component", type = "sb" },
      { field_id = 3, name = "category", label = "Category", type = "sb" },
    }

    config.options.fields.category = 9
    assert.equals(9, trackers.category_field(tracker(fields)).field_id)

    config.options.fields.category = "component"
    assert.equals(9, trackers.category_field(tracker(fields)).field_id)

    config.options.fields.category = false
    assert.is_nil(trackers.category_field(tracker(fields)))

    config.options.fields.category = previous
  end)

  it("is nil when the tracker has no such field", function()
    assert.is_nil(trackers.category_field(tracker({
      { field_id = 3, name = "status", label = "Status", type = "sb" },
    })))
  end)
end)

describe("the common form", function()
  local previous_mode

  before_each(function()
    require("tuleap.cache").invalidate()
    previous_mode = config.options.ui.form_fields
    config.options.ui.form_fields = "common"
  end)

  after_each(function()
    config.options.ui.form_fields = previous_mode
  end)

  it("offers the category when editing", function()
    local ids = form_field_ids(function()
      actions.edit(1234)
    end)
    assert.is_true(vim.tbl_contains(ids, 8), vim.inspect(ids))
  end)

  it("offers the category when creating", function()
    local ids = form_field_ids(function()
      actions.create(7)
    end)
    assert.is_true(vim.tbl_contains(ids, 8), vim.inspect(ids))
  end)

  it("leaves the category out when the role is disabled", function()
    local previous = config.options.fields.category
    config.options.fields.category = false
    local ids = form_field_ids(function()
      actions.edit(1234)
    end)
    config.options.fields.category = previous
    assert.is_false(vim.tbl_contains(ids, 8), vim.inspect(ids))
  end)
end)
