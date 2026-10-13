---@mod tuleap.ui.render Line builder
---
--- Builds buffer lines out of `{text, highlight}` chunks while tracking byte
--- offsets, so views never compute extmark columns by hand.

local M = {}

---@class tuleap.Builder
---@field lines string[]
---@field highlights {row: integer, col: integer, end_col: integer, hl: string}[]
local Builder = {}
Builder.__index = Builder

---@param width integer? used by `rule` and `wrap`
---@return tuleap.Builder
function M.builder(width)
  return setmetatable({ lines = {}, highlights = {}, width = width or 80, anchors = {} }, Builder)
end

---@alias tuleap.Chunk string|{[1]: string, [2]: string?}

--- Append one line made of chunks.
---@param chunks tuleap.Chunk[]|string|nil
---@return integer row 0-based index of the appended line
function Builder:line(chunks)
  if chunks == nil then
    chunks = { "" }
  elseif type(chunks) == "string" then
    chunks = { { chunks } }
  end
  local parts, offset = {}, 0
  local row = #self.lines
  for _, chunk in ipairs(chunks) do
    local text, hl
    if type(chunk) == "string" then
      text = chunk
    else
      text, hl = chunk[1], chunk[2]
    end
    text = tostring(text or "")
    if hl and #text > 0 then
      self.highlights[#self.highlights + 1] =
        { row = row, col = offset, end_col = offset + #text, hl = hl }
    end
    parts[#parts + 1] = text
    offset = offset + #text
  end
  self.lines[row + 1] = table.concat(parts)
  return row
end

--- Append several raw lines sharing one highlight.
---@param lines string[]
---@param hl string?
---@param indent string?
function Builder:raw(lines, hl, indent)
  for _, text in ipairs(lines) do
    self:line({ { (indent or "") .. text, hl } })
  end
end

--- `  Label  value` with aligned labels.
---@param label string
---@param value string|nil
---@param opts {width: integer?, hl: string?, label_hl: string?, indent: string?}?
---@return integer row
function Builder:field(label, value, opts)
  opts = opts or {}
  local pad = opts.width or 14
  local indent = opts.indent or "  "
  local text = label .. (" "):rep(math.max(1, pad - vim.fn.strdisplaywidth(label)))
  return self:line({
    { indent .. text, opts.label_hl or "TuleapLabel" },
    { tostring(value == nil and "—" or value), opts.hl or "TuleapValue" },
  })
end

--- Horizontal rule.
---@param char string?
---@param width integer?
function Builder:rule(char, width)
  self:line({ { ("  " .. (char or "─"):rep(math.max(4, (width or self.width) - 4))), "TuleapSeparator" } })
end

--- Section heading with a blank line before it.
---@param text string
function Builder:section(text)
  if #self.lines > 0 then
    self:line()
  end
  self:line({ { "  " .. text, "TuleapHeader" } })
end

function Builder:blank()
  self:line()
end

--- Wrap `text` to the builder width and append it.
---@param text string
---@param opts {indent: string?, hl: string?, width: integer?}?
function Builder:wrap(text, opts)
  opts = opts or {}
  local indent = opts.indent or "  "
  local width = (opts.width or self.width) - #indent - 2
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    paragraph = paragraph:gsub("\r", "")
    if paragraph == "" then
      self:line()
    else
      local current = ""
      for word in paragraph:gmatch("%S+") do
        if current == "" then
          current = word
        elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
          current = current .. " " .. word
        else
          self:line({ { indent .. current, opts.hl } })
          current = word
        end
      end
      if current ~= "" then
        self:line({ { indent .. current, opts.hl } })
      end
    end
  end
end

--- Remember the row a logical item starts at, so views can map cursor -> item.
---@param key any
---@param value any
function Builder:anchor(key, value)
  self.anchors[#self.lines] = { key = key, value = value }
end

--- Merge another builder's output (used to inline a rendered chart).
---@param output {lines: string[], highlights: table[]}
function Builder:append(output)
  local base = #self.lines
  for _, line in ipairs(output.lines) do
    self.lines[#self.lines + 1] = line
  end
  for _, item in ipairs(output.highlights or {}) do
    self.highlights[#self.highlights + 1] = {
      row = item.row + base,
      col = item.col,
      end_col = item.end_col,
      hl = item.hl,
    }
  end
end

--- Strip HTML tags and entities — Tuleap returns rich text for `text` fields
--- when the field format is `html`.
---@param html string
---@return string
function M.strip_html(html)
  if type(html) ~= "string" then
    return ""
  end
  local text = html
    :gsub("<br%s*/?>", "\n")
    :gsub("</p>", "\n")
    :gsub("</li>", "\n")
    :gsub("<li>", "  • ")
    :gsub("<[^>]->", "")
    :gsub("&nbsp;", " ")
    :gsub("&amp;", "&")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&#0?39;", "'")
  return (text:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

M.Builder = Builder

return M
