---@mod tuleap.util.format Guess the format of a text typed by the user
---
--- Tuleap stores each comment in one of three formats — "text", "html" or
--- "commonmark" — and renders it accordingly. Sending markdown as "text" shows
--- the raw asterisks and hashes, so the format is inferred from the text.

local M = {}

--- Tags worth taking as HTML. A bare `<` or `a <b> c` in prose would not be
--- enough on its own, so only tags followed by `>`, `/` or an attribute count.
-- stylua: ignore
local HTML_TAGS = {
  "p", "br", "div", "span", "b", "i", "u", "s", "strong", "em", "code", "pre",
  "a", "ul", "ol", "li", "blockquote", "table", "thead", "tbody", "tr", "td",
  "th", "img", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
}

--- Line-level markdown constructs: headings, lists, quotes, fences, tables and
--- thematic breaks.
local MARKDOWN_LINES = {
  "^#+%s+%S",
  "^%s*[-*+]%s+%S",
  "^%s*%d+[.)]%s+%S",
  "^%s*>%s?%S",
  "^%s*```",
  "^%s*~~~",
  "^%s*|.+|%s*$",
  "^%s*[-*_]%s*[-*_]%s*[-*_][-*_%s]*$",
}

--- Inline markdown constructs: strong emphasis, code spans, links and
--- strikethrough. Single `_` and `*` are left out: identifiers and arithmetic
--- use them too often.
local MARKDOWN_INLINE = {
  "%*%*[^%s*][^\n]-%*%*",
  "__[^%s_][^\n]-__",
  "`[^`\n]+`",
  "!?%[[^%]\n]+%]%([^)%s]+%)",
  "~~[^%s~][^\n]-~~",
}

---@param text string
---@return boolean
local function has_html(text)
  local lower = text:lower()
  for _, tag in ipairs(HTML_TAGS) do
    if lower:find("</?" .. tag .. "[%s/>]") then
      return true
    end
  end
  return false
end

---@param text string
---@return boolean
local function has_markdown(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    for _, pattern in ipairs(MARKDOWN_LINES) do
      if line:find(pattern) then
        return true
      end
    end
  end
  for _, pattern in ipairs(MARKDOWN_INLINE) do
    if text:find(pattern) then
      return true
    end
  end
  return false
end

--- The Tuleap format `text` is written in.
---
--- A text wrapped in a tag from start to end is HTML whatever it contains.
--- Otherwise markdown wins over HTML, since commonmark accepts inline HTML
--- while the reverse would show the markdown raw.
---@param text string?
---@return "text"|"html"|"commonmark"
function M.detect(text)
  if type(text) ~= "string" then
    return "text"
  end
  local trimmed = vim.trim(text)
  if trimmed == "" then
    return "text"
  end
  if trimmed:find("^<%a") and trimmed:find("</%a[%w]*>$") and has_html(trimmed) then
    return "html"
  end
  if has_markdown(trimmed) then
    return "commonmark"
  end
  if has_html(trimmed) then
    return "html"
  end
  return "text"
end

return M
