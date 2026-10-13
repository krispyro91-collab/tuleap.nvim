local render = require("tuleap.ui.render")

describe("render.builder", function()
  it("tracks byte offsets of highlighted chunks", function()
    local builder = render.builder(40)
    builder:line({ { "ab", "A" }, { "cdé", "B" } })
    assert.same({ "abcdé" }, builder.lines)
    assert.same({ row = 0, col = 0, end_col = 2, hl = "A" }, builder.highlights[1])
    -- "é" is two bytes: the highlight must use byte columns, not characters.
    assert.same({ row = 0, col = 2, end_col = 6, hl = "B" }, builder.highlights[2])
  end)

  it("wraps text to the available width", function()
    local builder = render.builder(30)
    builder:wrap(("word "):rep(20))
    for _, line in ipairs(builder.lines) do
      assert.is_true(#line <= 30)
    end
    assert.is_true(#builder.lines > 1)
  end)

  it("keeps explicit newlines when wrapping", function()
    local builder = render.builder(40)
    builder:wrap("one\n\ntwo")
    assert.same({ "  one", "", "  two" }, builder.lines)
  end)

  it("appends another output and shifts its highlights", function()
    local builder = render.builder(40)
    builder:line({ { "header" } })
    builder:append({ lines = { "a", "b" }, highlights = { { row = 1, col = 0, end_col = 1, hl = "X" } } })
    assert.same({ "header", "a", "b" }, builder.lines)
    assert.equals(2, builder.highlights[#builder.highlights].row)
  end)
end)

describe("render.strip_html", function()
  it("turns Tuleap rich text into readable plain text", function()
    assert.equals("Hello world", render.strip_html("<p>Hello <b>world</b></p>"))
    assert.equals("a\nb", render.strip_html("a<br/>b"))
    assert.equals("<tag> & \"quoted\"", render.strip_html("&lt;tag&gt; &amp; &quot;quoted&quot;"))
    assert.equals("", render.strip_html(nil))
  end)
end)
