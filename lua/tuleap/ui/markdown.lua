---@mod tuleap.ui.markdown Optional render-markdown.nvim integration
---
--- When render-markdown.nvim is installed, the artifact view keeps rich text
--- (descriptions, comments) as markdown and hands the buffer to the plugin's
--- one-shot `render()` API. Forms already use `filetype=markdown`, so the
--- plugin attaches to them on its own.

local config = require("tuleap.config")

local M = {}

--- Filetype of the artifact view, parsed as markdown when rendering.
M.FILETYPE = "tuleap-artifact"

local registered = false

--- The render-markdown module, or nil when it is absent or disabled.
---@return table?
local function plugin()
  if config.options.ui.render_markdown == false then
    return nil
  end
  local ok, mod = pcall(require, "render-markdown")
  if ok and type(mod) == "table" and type(mod.render) == "function" then
    return mod
  end
  return nil
end

--- Whether text fields should be laid out as markdown.
---@return boolean
function M.enabled()
  return plugin() ~= nil
end

--- Quiet period before rendering, see `M.render`.
M.DEBOUNCE_MS = 50

---@type table<integer, uv.uv_timer_t>
local timers = {}

--- Render the markdown in `buf`. A no-op without render-markdown.
---
--- Debounced: views redraw several times in a row as their requests answer,
--- each time replacing every line, and the marks of a pass rendered on an
--- earlier version collapse to the end of the buffer. Rendering once the
--- redraws settle keeps the final content decorated.
---@param buf integer
---@param win integer?
function M.render(buf, win)
  if not plugin() then
    return
  end
  local timer = timers[buf]
  if not timer then
    timer = assert(vim.uv.new_timer())
    timers[buf] = timer
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        timers[buf] = nil
        timer:stop()
        timer:close()
      end,
    })
  end
  timer:stop()
  timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    M.render_now(buf, win)
  end))
end

--- Render immediately, without waiting for redraws to settle.
---@param buf integer
---@param win integer?
function M.render_now(buf, win)
  local mod = plugin()
  if not mod or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if win and not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
    return
  end
  if not registered then
    -- render-markdown picks the parser from the buffer's filetype.
    pcall(vim.treesitter.language.register, "markdown", M.FILETYPE)
    registered = true
  end
  if not vim.b[buf].tuleap_markdown then
    -- render-markdown draws blocks (headings, lists, code); emphasis and
    -- links are concealed by the markdown highlighter, as in a .md file.
    vim.b[buf].tuleap_markdown = pcall(vim.treesitter.start, buf, "markdown")
  end
  pcall(mod.render, {
    buf = buf,
    win = win,
    -- The view is re-rendered on every redraw and never edited, so the raw
    -- markdown under the cursor would only flicker in and out of view.
    config = {
      anti_conceal = { enabled = false },
      -- render-markdown's `debounce` is a throttle: a request arriving within
      -- that window after another one is dropped, with no trailing render.
      -- Redraws are coalesced above instead, so every request must count.
      debounce = 0,
    },
  })
end

--- Turn the HTML Tuleap's rich text editor produces into markdown, so it
--- renders as well as a commonmark field. Anything unknown is stripped.
---@param html string
---@return string
function M.from_html(html)
  if type(html) ~= "string" then
    return ""
  end
  local text = html:gsub("\r", "")
  -- Code blocks first, before `<code>` turns into inline backticks.
  text = text:gsub("<pre[^>]*>%s*<code[^>]*>(.-)</code>%s*</pre>", "\n```\n%1\n```\n")
  text = text:gsub("<pre[^>]*>(.-)</pre>", "\n```\n%1\n```\n")
  for level = 1, 6 do
    text = text:gsub(("<h%d[^>]*>(.-)</h%d>"):format(level, level), "\n" .. ("#"):rep(level) .. " %1\n")
  end
  text = text
    :gsub("<a [^>]-href=\"([^\"]*)\"[^>]*>(.-)</a>", "[%2](%1)")
    :gsub("<%s*/?%s*strong%s*>", "**")
    :gsub("<%s*/?%s*b%s*>", "**")
    :gsub("<%s*/?%s*em%s*>", "_")
    :gsub("<%s*/?%s*i%s*>", "_")
    :gsub("<%s*/?%s*code[^>]*>", "`")
    :gsub("<li[^>]*>%s*", "\n- ")
    :gsub("</[uo]l>", "\n\n")
    :gsub("<br%s*/?>", "  \n")
    :gsub("</p>", "\n\n")
    :gsub("<[^>]->", "")
    :gsub("&nbsp;", " ")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&#0?39;", "'")
    :gsub("&amp;", "&")
  return vim.trim((text:gsub("[ \t]+\n", function(spaces)
    -- Keep the two-space hard breaks, drop any other trailing blanks.
    return spaces:sub(1, 2) == "  " and "  \n" or "\n"
  end):gsub("\n\n\n+", "\n\n")))
end

--- Markdown source of a Tuleap comment.
---@param comment table `last_comment` of a changeset
---@return string
function M.comment_source(comment)
  if type(comment.commonmark) == "string" and comment.commonmark ~= "" then
    return vim.trim(comment.commonmark)
  end
  if comment.format == "html" then
    return M.from_html(comment.body)
  end
  -- "text" and "commonmark" bodies are already markdown-ish source.
  return vim.trim(tostring(comment.body or ""))
end

--- Markdown source of a rich text field value.
---@param value table artifact field value
---@param rendered string the value as `trackers.render_value` shows it
---@return string
function M.text_source(value, rendered)
  if type(value.commonmark) == "string" then
    return vim.trim(value.commonmark)
  end
  local format = value.format or (type(value.value) == "table" and value.value.format)
  if format == "html" then
    return M.from_html(rendered)
  end
  return vim.trim(rendered)
end

--- Append markdown as-is: re-wrapping it would break lists, tables and code
--- blocks, and the window soft-wraps anyway. Two spaces of indent keep every
--- construct intact (four would turn paragraphs into code blocks), and the
--- leading blank line stops the line above from being read as part of it — a
--- table header, or a setext heading over a `---`.
---@param builder tuleap.Builder
---@param text string
function M.append(builder, text)
  builder:blank()
  builder:raw(vim.split(text:gsub("\r", ""), "\n", { plain = true }), nil, "  ")
end

return M
