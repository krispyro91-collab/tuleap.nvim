local form = require("tuleap.ui.form")
local trackers = require("tuleap.api.trackers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

---@param artifact table
---@return string[] buffer lines
local function open_edit_form(artifact)
  local by_id = {}
  for _, value in ipairs(artifact.values) do
    by_id[value.field_id] = value
  end
  local win = form.open({
    title = "Edit",
    fields = trackers.editable_fields(fixtures.tracker),
    values = by_id,
    comment = true,
    on_submit = function() end,
  })
  local lines = win:get_lines()
  vim.bo[win.buf].modified = false
  win:close()
  return lines
end

---@param lines string[]
---@param heading string
---@return string body of that `### ` section
local function section(lines, heading)
  local body, collecting = {}, false
  for _, line in ipairs(lines) do
    if line:match("^###%s") then
      collecting = vim.trim(line):find(heading, 1, true) ~= nil
    elseif collecting then
      body[#body + 1] = line
    end
  end
  return vim.trim(table.concat(body, "\n"))
end

describe("edit form prefilling", function()
  it("fills every section from a labelled artifact representation", function()
    local lines = open_edit_form(fixtures.artifact)
    assert.equals("SSO redirect loops on first login", section(lines, "Summary"))
    assert.equals("In progress", section(lines, "Status"))
    assert.equals("Alice Martin (alice)", section(lines, "Assigned to"))
    assert.equals("3", section(lines, "Remaining effort"))
    assert.equals("High", section(lines, "Priority"))
    assert.is_true(section(lines, "Description"):find("SAML", 1, true) ~= nil)
  end)

  it("fills list fields that only carry bind_value_ids", function()
    local lines = open_edit_form(fixtures.artifact_bind_ids)
    -- This is the regression: without the tracker schema these were blank.
    assert.equals("In progress", section(lines, "Status"))
    assert.equals("High", section(lines, "Priority"))
    assert.equals("Alice Martin (alice), Bob Dupont (bob)", section(lines, "Assigned to"))
  end)

  it("strips html out of flat text fields", function()
    local lines = open_edit_form(fixtures.artifact_bind_ids)
    local description = section(lines, "Description")
    assert.is_nil(description:find("<p>", 1, true))
    assert.is_true(description:find("SAML", 1, true) ~= nil)
  end)

  it("marks required fields and keeps a Comment section", function()
    local lines = open_edit_form(fixtures.artifact)
    local text = table.concat(lines, "\n")
    assert.is_true(text:find("### Summary *", 1, true) ~= nil)
    assert.is_true(text:find("### Comment", 1, true) ~= nil)
  end)
end)
