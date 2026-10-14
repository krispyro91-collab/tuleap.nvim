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

--- Submit `lines` through a form and return the values it would send.
---@param artifact table
---@param edit fun(lines: string[]): string[]
---@return table[]? values, string? err
local function submit_form(artifact, edit)
  local by_id = {}
  for _, value in ipairs(artifact.values) do
    by_id[value.field_id] = value
  end
  local captured, failure
  local notify = vim.notify
  vim.notify = function(msg)
    failure = msg
  end
  local win = form.open({
    title = "Edit",
    fields = trackers.editable_fields(fixtures.tracker),
    values = by_id,
    on_submit = function(values)
      captured = values
    end,
  })
  vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, edit(win:get_lines()))
  vim.api.nvim_buf_call(win.buf, function()
    vim.cmd("silent write")
  end)
  -- Validation errors are reported through `vim.schedule`, so let them land.
  vim.wait(500, function()
    return captured ~= nil or failure ~= nil
  end, 10)
  vim.bo[win.buf].modified = false
  win:close()
  vim.notify = notify
  return captured, failure
end

---@param values table[]?
---@param field_id integer
---@return table?
local function value_for(values, field_id)
  for _, value in ipairs(values or {}) do
    if value.field_id == field_id then
      return value
    end
  end
end

describe("form round-trip of bound values", function()
  it("sends nothing at all when the form is submitted unchanged", function()
    -- The regression had two halves: the form renders "Alice Martin (alice)"
    -- while the field lists that value as "alice", so an untouched submit
    -- cleared the assignee; and every other field was rewritten too.
    local values, err = submit_form(fixtures.artifact, function(lines)
      return lines
    end)
    assert.is_nil(err)
    assert.equals(0, #values, "an untouched form must not write anything")
  end)

  it("sends only the field that changed", function()
    local values, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "SSO redirect loops on first login" then
          lines[index] = "a new summary"
        end
      end
      return lines
    end)
    assert.is_nil(err)
    assert.equals(1, #values)
    assert.equals(1, values[1].field_id)
    assert.is_nil(value_for(values, 4), "the untouched assignee must stay out of the payload")
  end)

  it("still resolves the rendered assignee when it is edited", function()
    local values, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "Alice Martin (alice)" then
          lines[index] = "Alice Martin (alice), Bob Dupont (bob)"
        end
      end
      return lines
    end)
    assert.is_nil(err)
    assert.same({ 102, 103 }, value_for(values, 4).bind_value_ids)
  end)

  it("accepts the bare username too", function()
    local values, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "Alice Martin (alice)" then
          lines[index] = "alice"
        end
      end
      return lines
    end)
    assert.is_nil(err)
    assert.same({ 102 }, value_for(values, 4).bind_value_ids)
  end)

  it("accepts a different case and surrounding whitespace", function()
    local values, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "Alice Martin (alice)" then
          lines[index] = "  ALICE MARTIN (ALICE)  "
        end
      end
      return lines
    end)
    assert.is_nil(err)
    assert.same({ 102 }, value_for(values, 4).bind_value_ids)
  end)

  it("resolves several assignees at once", function()
    local values, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "Alice Martin (alice)" then
          lines[index] = "Alice Martin (alice), bob"
        end
      end
      return lines
    end)
    assert.is_nil(err)
    assert.same({ 102, 103 }, value_for(values, 4).bind_value_ids)
  end)

  it("suggests close matches instead of listing everything", function()
    local _, err = submit_form(fixtures.artifact, function(lines)
      for index, line in ipairs(lines) do
        if line == "Alice Martin (alice)" then
          lines[index] = "alicce"
        end
      end
      return lines
    end)
    assert.is_not_nil(err)
    assert.is_true(err:find("is not a valid value", 1, true) ~= nil)
  end)
end)

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

  it("offers the commonmark source of a rich text field", function()
    -- Editing a stripped-to-plain-text rendering would replace the formatted
    -- description with its own flattened shadow on submit.
    local lines = open_edit_form(fixtures.artifact_bind_ids)
    assert.equals("Logging in through the **SAML** provider bounces.", section(lines, "Description"))
  end)

  it("keeps a rich description out of the payload unless it is edited", function()
    local values = submit_form(fixtures.artifact_bind_ids, function(lines)
      return lines
    end)
    assert.is_nil(value_for(values, 2), "an untouched html description must not be rewritten")
  end)

  it("sends an edited text field back in its own format", function()
    local values, err = submit_form(fixtures.artifact_bind_ids, function(lines)
      for index, line in ipairs(lines) do
        if line:find("SAML", 1, true) then
          lines[index] = "rewritten **body**"
        end
      end
      return lines
    end)
    assert.is_nil(err)
    local description = value_for(values, 2)
    assert.equals("rewritten **body**", description.value.content)
    -- commonmark, not "text": the server must not store the markup literally.
    assert.equals("commonmark", description.value.format)
  end)

  it("preserves the stored format when asked to", function()
    local previous = require("tuleap.config").options.ui.text_format
    require("tuleap.config").options.ui.text_format = "preserve"
    local lines = open_edit_form(fixtures.artifact_bind_ids)
    assert.equals(
      "<p>Logging in through the <b>SAML</b> provider bounces.</p>",
      section(lines, "Description")
    )
    local values = submit_form(fixtures.artifact_bind_ids, function(buffer)
      for index, line in ipairs(buffer) do
        if line:find("SAML", 1, true) then
          buffer[index] = "<p>rewritten</p>"
        end
      end
      return buffer
    end)
    assert.equals("html", value_for(values, 2).value.format)
    require("tuleap.config").options.ui.text_format = previous
  end)

  it("marks required fields and keeps a Comment section", function()
    local lines = open_edit_form(fixtures.artifact)
    local text = table.concat(lines, "\n")
    assert.is_true(text:find("### Summary *", 1, true) ~= nil)
    assert.is_true(text:find("### Comment", 1, true) ~= nil)
  end)
end)
