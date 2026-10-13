local pickers = require("tuleap.pickers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

describe("pickers.entry_maker", function()
  local has_telescope = pcall(require, "telescope")

  it("produces a searchable ordinal and a renderable display", function()
    if not has_telescope then
      return
    end
    local make = pickers.entry_maker(fixtures.artifacts)
    local entry = make(fixtures.artifact)

    assert.equals(fixtures.artifact, entry.value)
    assert.is_true(entry.ordinal:find("bug #1234", 1, true) ~= nil)
    assert.is_true(entry.ordinal:find("SSO redirect", 1, true) ~= nil)

    -- `display` is a function telescope calls while drawing: it must not throw
    -- and must mention the artifact.
    local text = type(entry.display) == "function" and entry.display(entry) or entry.display
    assert.is_string(text)
    assert.is_true(text:find("SSO redirect", 1, true) ~= nil)
    assert.is_true(text:find("1234", 1, true) ~= nil)
  end)

  it("handles artifacts with no values at all", function()
    if not has_telescope then
      return
    end
    local make = pickers.entry_maker({ { id = 9 } })
    local entry = make({ id = 9 })
    local text = type(entry.display) == "function" and entry.display(entry) or entry.display
    assert.is_true(text:find("9", 1, true) ~= nil)
  end)
end)

describe("pickers.artifact_preview", function()
  it("renders the artifact body, status and fields", function()
    local builder = pickers.artifact_preview(fixtures.artifact, 70)
    local text = table.concat(builder.lines, "\n")
    assert.is_true(text:find("bug #1234", 1, true) ~= nil)
    assert.is_true(text:find("In progress", 1, true) ~= nil)
    assert.is_true(text:find("Description", 1, true) ~= nil)
    assert.is_true(text:find("SAML", 1, true) ~= nil)
    -- HTML must have been stripped out of the description.
    assert.is_nil(text:find("<b>", 1, true))
    for _, line in ipairs(builder.lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 72, "preview line too wide: " .. line)
    end
  end)
end)
