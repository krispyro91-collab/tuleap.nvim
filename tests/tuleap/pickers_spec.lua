local pickers = require("tuleap.pickers")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

describe("pickers.entry_columns", function()
  it("shows the state icon, xref, status and title", function()
    local columns = pickers.entry_columns(fixtures.artifact)
    local texts = vim.tbl_map(function(column)
      return column[1]
    end, columns)
    assert.is_true(vim.tbl_contains(texts, "bug #1234"))
    assert.is_true(vim.tbl_contains(texts, "In progress"))
    assert.is_true(vim.tbl_contains(texts, "SSO redirect loops on first login"))
    for _, column in ipairs(columns) do
      assert.is_string(column[1])
      assert.is_string(column[2])
    end
  end)

  it("highlights open and closed artifacts differently", function()
    local open = pickers.entry_columns({ id = 1, status = "New", is_open = true })
    local closed = pickers.entry_columns({ id = 2, status = "Fixed", is_open = false })
    assert.equals("TuleapOpen", open[1][2])
    assert.equals("TuleapClosed", closed[1][2])
  end)

  it("handles artifacts with no values at all", function()
    local columns = pickers.entry_columns({ id = 9 })
    local text = table.concat(vim.tbl_map(function(column)
      return column[1]
    end, columns), " ")
    assert.is_true(text:find("9", 1, true) ~= nil)
  end)
end)

describe("pickers.entry_ordinal", function()
  it("makes the xref, status and title searchable", function()
    local ordinal = pickers.entry_ordinal(fixtures.artifact)
    assert.is_true(ordinal:find("bug #1234", 1, true) ~= nil)
    assert.is_true(ordinal:find("In progress", 1, true) ~= nil)
    assert.is_true(ordinal:find("SSO redirect", 1, true) ~= nil)
  end)
end)

describe("pickers.entry_maker", function()
  it("wraps each artifact with its value, ordinal and a display callback", function()
    local make = pickers.entry_maker(fixtures.artifacts)
    local entry = make(fixtures.artifact)
    assert.equals(fixtures.artifact, entry.value)
    assert.equals(pickers.entry_ordinal(fixtures.artifact), entry.ordinal)
    -- `display` is only callable inside a running picker (telescope resolves
    -- the remaining column against the picker layout), so only its presence is
    -- asserted here; the rendered content is covered by entry_columns above.
    assert.is_true(type(entry.display) == "function" or type(entry.display) == "string")
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

  it("keeps the description as markdown for render-markdown.nvim", function()
    local builder = pickers.artifact_preview(fixtures.artifact, 70, true)
    local text = table.concat(builder.lines, "\n")
    assert.truthy(text:find("**SAML**", 1, true), "description lost its markdown")
    assert.is_nil(text:find("<b>", 1, true))
  end)
end)
