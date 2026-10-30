local format = require("tuleap.util.format")

describe("format.detect", function()
  it("takes plain prose as text", function()
    assert.equals("text", format.detect("Reproduced on staging with a brand new account."))
    assert.equals("text", format.detect("if a < b and c > d, swap them"))
    assert.equals("text", format.detect("2 * 3 * 4 is 24, see snake_case_name"))
    assert.equals("text", format.detect(""))
    assert.equals("text", format.detect(nil))
  end)

  it("recognises markdown blocks", function()
    for _, text in ipairs({
      "## Steps\nlog in",
      "Steps:\n- log in\n- log out",
      "1. log in\n2. log out",
      "> quoted from the ticket",
      "```lua\nprint(1)\n```",
      "| a | b |\n|---|---|\n| 1 | 2 |",
      "above\n\n---\n\nbelow",
    }) do
      assert.equals("commonmark", format.detect(text), text)
    end
  end)

  it("recognises inline markdown", function()
    for _, text in ipairs({
      "this is **important**",
      "run `make test` first",
      "see [the docs](https://example.test/docs)",
      "~~not~~ fixed",
    }) do
      assert.equals("commonmark", format.detect(text), text)
    end
  end)

  it("recognises HTML", function()
    assert.equals("html", format.detect("<p>Patch is on <code>fix/sso-loop</code>.</p>"))
    assert.equals("html", format.detect("Line one<br>line two"))
    assert.equals("html", format.detect('Go <a href="https://example.test">there</a>'))
  end)

  it("prefers markdown when both appear, since commonmark allows inline HTML", function()
    assert.equals("commonmark", format.detect("## Note\nline one<br>line two"))
  end)

  it("keeps a text wrapped in one HTML element as HTML", function()
    assert.equals("html", format.detect("<div>\n- not a list here\n</div>"))
  end)
end)
