---@mod tuleap.ui.form Editable forms
---
--- Forms are plain markdown buffers: each field is a `### Label` heading
--- followed by its value. That keeps multi-line text fields natural to edit and
--- survives any editing the user does, including reordering or deleting a
--- section (a missing section simply leaves the field untouched).
---
--- `<CR>` on a list field opens |vim.ui.select| so the user never has to guess
--- the exact wording of a bound value.

local config = require("tuleap.config")
local log = require("tuleap.util.log")
local render = require("tuleap.ui.render")
local trackers = require("tuleap.api.trackers")
local window = require("tuleap.ui.window")

local M = {}

local HEADING = "### "

---@param field table
---@return string
local function heading_for(field)
  local suffix = field.required and " *" or ""
  local hint = ""
  if field.type == "sb" or field.type == "rb" then
    hint = "  (list)"
  elseif field.type == "msb" or field.type == "cb" or field.type == "tbl" then
    hint = "  (list, comma separated)"
  elseif field.type == "date" then
    hint = "  (YYYY-MM-DD)"
  elseif field.type == "int" or field.type == "float" or field.type == "computed" then
    hint = "  (number)"
  end
  return HEADING .. field.label .. suffix .. hint
end

--- The editable source of a rich text field, and the format to send it back as.
---
--- Tuleap stores descriptions as HTML on many trackers and also exposes the
--- equivalent markdown under `commonmark`. Editing the markdown is pleasant
--- and Tuleap accepts it on write; editing a stripped-to-plain-text rendering
--- is not, because submitting it would replace the formatted description with
--- its own flattened shadow.
---@param value table? artifact field value
---@return string content, string format
local function text_source(value)
  if type(value) ~= "table" then
    return "", "text"
  end
  if config.options.ui.text_format == "commonmark" and type(value.commonmark) == "string" then
    return value.commonmark, "commonmark"
  end
  local content = value.value
  if type(content) == "table" then
    content = content.content
  end
  local format = value.format
  if type(format) ~= "string" then
    format = type(value.value) == "table" and value.value.format or "text"
  end
  return tostring(content or ""), type(format) == "string" and format or "text"
end

--- Labels currently selected on a bound field, taken from the artifact values.
---@param field table
---@param values table<integer, table> artifact values indexed by field_id
---@return string content, string? text_format
local function current_value(field, values)
  local value = values[field.field_id]
  if not value then
    return "", field.type == "text" and "text" or nil
  end
  if field.type == "text" then
    return text_source(value)
  end
  -- The field definition is what turns `bind_value_ids` back into labels.
  return trackers.render_value(value, field)
end

---@param field table
---@return table[] values
local function bound_values(field)
  local out = {}
  for _, value in ipairs(field.values or {}) do
    if not value.is_hidden then
      out[#out + 1] = value
    end
  end
  return out
end

---@param value table
---@return string
local function value_label(value)
  return trackers.value_display(value)
end

--- Resolve user-typed labels back to bind value ids.
---@param field table
---@param text string
---@return integer[]? ids, string? err
local function ids_from_text(field, text)
  local ids = {}
  local wanted = {}
  for part in tostring(text or ""):gmatch("[^,]+") do
    part = vim.trim(part)
    if part ~= "" then
      wanted[#wanted + 1] = part
    end
  end
  if #wanted == 0 then
    -- "None" is id 100 in Tuleap for every static list binding.
    return {}
  end
  for _, needle in ipairs(wanted) do
    local lowered = needle:lower()
    -- "PIAULT Christophe 00023610 (cqb)" also identifies the value "cqb".
    local parenthetical = needle:match("%(([^()]+)%)%s*$")
    local found

    for _, value in ipairs(bound_values(field)) do
      for _, alias in ipairs(trackers.value_aliases(value)) do
        if alias:lower() == lowered or (parenthetical and alias:lower() == parenthetical:lower()) then
          found = value.id
          break
        end
      end
      if found then
        break
      end
    end

    if not found then
      -- Listing 29 users helps nobody; show the ones that look close.
      local close, all = {}, {}
      for _, value in ipairs(bound_values(field)) do
        local display = value_label(value)
        all[#all + 1] = display
        for _, alias in ipairs(trackers.value_aliases(value)) do
          if alias:lower():find(lowered, 1, true) or lowered:find(alias:lower(), 1, true) then
            close[#close + 1] = display
            break
          end
        end
      end
      local suggestions = #close > 0 and close or all
      local shown = vim.list_slice(suggestions, 1, math.min(8, #suggestions))
      return nil,
        ("%s: %q is not a valid value.\n%s: %s%s"):format(
          field.label,
          needle,
          #close > 0 and "Did you mean" or "Valid values",
          table.concat(shown, ", "),
          #suggestions > #shown and (" … (%d more)"):format(#suggestions - #shown) or ""
        )
    end
    ids[#ids + 1] = found
  end
  return ids
end

---@class tuleap.FormOpts
---@field title string
---@field fields table[] tracker fields to render
---@field values table<integer, table>? current artifact values by field_id
---@field intro string[]? comment lines shown at the top
---@field comment boolean? append a free-form "Comment" section
---@field on_submit fun(values: table[], comment: string?, close: fun())

--- Open a form.
---@param opts tuleap.FormOpts
function M.open(opts)
  local keys = config.options.keymaps.form
  local win = window.open({
    title = opts.title,
    filetype = "markdown",
    modifiable = true,
    footer = config.options.ui.show_help_hint
        and ("%s submit  %s abort  %s pick value  %s help"):format(
          keys.submit or keys.submit_alt or "-",
          keys.abort or "-",
          keys.pick_value or "-",
          keys.help or "-"
        )
      or nil,
  })

  local lines = {}
  for _, line in ipairs(opts.intro or {}) do
    lines[#lines + 1] = "<!-- " .. line .. " -->"
  end
  if #lines > 0 then
    lines[#lines + 1] = ""
  end

  ---@type {field: table, heading: string, initial: string, format: string?}[]
  local sections = {}
  for _, field in ipairs(opts.fields) do
    local heading = heading_for(field)
    local value, format = current_value(field, opts.values or {})
    sections[#sections + 1] =
      { field = field, heading = heading, initial = vim.trim(value), format = format }
    lines[#lines + 1] = heading
    for _, value_line in ipairs(vim.split(value, "\n", { plain = true })) do
      lines[#lines + 1] = value_line
    end
    lines[#lines + 1] = ""
  end

  local COMMENT_HEADING = HEADING .. "Comment"
  if opts.comment then
    lines[#lines + 1] = COMMENT_HEADING
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
  end

  win:set_lines(lines)
  vim.bo[win.buf].modifiable = true
  vim.bo[win.buf].buftype = "acwrite"
  vim.api.nvim_buf_set_name(win.buf, ("tuleap://form/%d"):format(win.buf))

  --- Split the buffer back into `heading -> text`.
  ---@return table<string, string> sections, string[] buffer_lines
  local function parse()
    local buffer_lines = win:get_lines()
    local known = {}
    for _, section in ipairs(sections) do
      known[section.heading] = true
    end
    known[COMMENT_HEADING] = true

    local out, current = {}, nil
    for _, line in ipairs(buffer_lines) do
      local trimmed = vim.trim(line)
      if known[trimmed] then
        current = trimmed
        out[current] = {}
      elseif current and not trimmed:match("^<!%-%-") then
        table.insert(out[current], line)
      end
    end
    local text = {}
    for heading, body in pairs(out) do
      text[heading] = vim.trim(table.concat(body, "\n"))
    end
    return text, buffer_lines
  end

  local function submit()
    local parsed = parse()
    local values, errors = {}, {}

    for _, section in ipairs(sections) do
      local raw = parsed[section.heading]
      local field = section.field
      if raw ~= nil and field.required and raw == "" then
        errors[#errors + 1] = ("%s is required"):format(field.label)
      elseif raw ~= nil and raw ~= section.initial then
        -- Only fields the user actually changed are sent. An untouched
        -- description is then never rewritten, whatever its format.
        if trackers.SCALAR_TYPES[field.type] then
          if (field.type == "int" or field.type == "float") and raw ~= "" and not tonumber(raw) then
            errors[#errors + 1] = ("%s must be a number"):format(field.label)
          elseif field.type == "date" and raw ~= "" and not raw:match("^%d%d%d%d%-%d%d%-%d%d") then
            errors[#errors + 1] = ("%s must look like YYYY-MM-DD"):format(field.label)
          else
            values[#values + 1] = trackers.value_payload(field, raw, { format = section.format })
          end
        else
          local ids, err = ids_from_text(field, raw)
          if err then
            errors[#errors + 1] = err
          else
            values[#values + 1] = trackers.value_payload(field, ids)
          end
        end
      end
    end

    if #errors > 0 then
      return log.error("Cannot submit:\n• " .. table.concat(errors, "\n• "))
    end

    local comment = opts.comment and parsed[COMMENT_HEADING] or nil
    opts.on_submit(values, comment ~= "" and comment or nil, function()
      if win:valid() then
        vim.bo[win.buf].modified = false
        win:close()
      end
    end)
  end

  --- The section the cursor currently sits in.
  ---@return table? section
  local function section_at_cursor()
    local row = vim.api.nvim_win_get_cursor(win.win)[1]
    local buffer_lines = win:get_lines()
    for index = row, 1, -1 do
      local trimmed = vim.trim(buffer_lines[index] or "")
      for _, section in ipairs(sections) do
        if section.heading == trimmed then
          return section, index
        end
      end
      if trimmed == COMMENT_HEADING then
        return nil
      end
    end
    return nil
  end

  --- Replace the body of a section with `text`.
  ---@param start_row integer 1-based row of the heading
  ---@param text string
  local function set_section(start_row, text)
    local buffer_lines = win:get_lines()
    local stop = #buffer_lines
    for index = start_row + 1, #buffer_lines do
      if vim.trim(buffer_lines[index] or ""):match("^###%s") then
        stop = index - 1
        break
      end
    end
    -- Keep one trailing blank line between sections.
    local replacement = vim.split(text, "\n", { plain = true })
    replacement[#replacement + 1] = ""
    vim.api.nvim_buf_set_lines(win.buf, start_row, stop, false, replacement)
  end

  local function pick()
    local section, row = section_at_cursor()
    if not section then
      return log.info("Put the cursor inside a list field to pick a value")
    end
    local field = section.field
    if trackers.SCALAR_TYPES[field.type] then
      return log.info(("%s is a free text field — just type in it"):format(field.label))
    end

    local choices = bound_values(field)
    if #choices == 0 then
      return log.warn(("%s has no selectable value"):format(field.label))
    end
    local multi = field.type == "msb" or field.type == "cb" or field.type == "tbl"
    local selected = {}

    local function prompt()
      local items = { "✓ done" }
      for _, value in ipairs(choices) do
        local label = value_label(value)
        items[#items + 1] = (multi and (selected[label] and "[x] " or "[ ] ") or "") .. label
      end
      vim.ui.select(items, {
        prompt = ("%s%s"):format(field.label, multi and " (multi-select)" or ""),
      }, function(choice)
        if not choice then
          return
        end
        if choice == "✓ done" then
          local labels = {}
          for _, value in ipairs(choices) do
            if selected[value_label(value)] then
              labels[#labels + 1] = value_label(value)
            end
          end
          return set_section(row, table.concat(labels, ", "))
        end
        local label = multi and choice:sub(5) or choice
        if multi then
          selected[label] = not selected[label]
          prompt()
        else
          set_section(row, label)
        end
      end)
    end

    if multi then
      for _, part in ipairs(vim.split(parse()[section.heading] or "", ",", { plain = true })) do
        part = vim.trim(part)
        if part ~= "" then
          selected[part] = true
        end
      end
    end
    prompt()
  end

  win:map(keys.submit, submit, "Submit", { "n", "i" })
  win:map(keys.submit_alt, submit, "Submit")
  win:map(keys.pick_value, pick, "Pick a value")
  win:map(keys.abort, function()
    vim.bo[win.buf].modified = false
    win:close()
  end, "Abort")
  win:map(keys.help, function()
    log.info(
      ("%s submit · %s abort · %s pick a list value\nSections are `### Label`; leave a section out to keep the current value."):format(
        keys.submit,
        keys.abort,
        keys.pick_value
      )
    )
  end, "Help")

  -- `q`/`<Esc>` must not discard an edited form by accident.
  vim.keymap.set("n", "q", function()
    if vim.bo[win.buf].modified then
      log.warn(("Form modified — %s to submit, %s to discard"):format(keys.submit, keys.abort))
    else
      win:close()
    end
  end, { buffer = win.buf, nowait = true, silent = true })
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = win.buf })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = win.buf,
    callback = submit,
  })

  -- Land on the first editable value rather than on the intro comment.
  local first = #(opts.intro or {}) > 0 and (#(opts.intro or {}) + 2) or 1
  pcall(vim.api.nvim_win_set_cursor, win.win, { math.min(first + 1, #lines), 0 })

  return win
end

--- Small multi-line text prompt, used for comments and TQL queries.
---@param opts {title: string, text: string?, intro: string[]?, height: integer?, on_submit: fun(text: string, close: fun())}
function M.input(opts)
  local keys = config.options.keymaps.form
  local win = window.open({
    title = opts.title,
    filetype = "markdown",
    modifiable = true,
    width = 0.6,
    height = opts.height or 12,
    footer = ("%s submit  %s abort"):format(keys.submit, keys.abort),
  })

  local lines = {}
  for _, line in ipairs(opts.intro or {}) do
    lines[#lines + 1] = "<!-- " .. line .. " -->"
  end
  for _, line in ipairs(vim.split(opts.text or "", "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  win:set_lines(lines)

  -- Same buffer contract as the field form: `:w` submits, and the buffer is
  -- writable so that typing `:w` out of habit does not fail with E382.
  vim.bo[win.buf].buftype = "acwrite"
  vim.api.nvim_buf_set_name(win.buf, ("tuleap://input/%d"):format(win.buf))
  vim.bo[win.buf].modified = false

  local function submit()
    local body = {}
    for _, line in ipairs(win:get_lines()) do
      if not vim.trim(line):match("^<!%-%-") then
        body[#body + 1] = line
      end
    end
    opts.on_submit(vim.trim(table.concat(body, "\n")), function()
      if win:valid() then
        vim.bo[win.buf].modified = false
        win:close()
      end
    end)
  end

  win:map(keys.submit, submit, "Submit", { "n", "i" })
  win:map(keys.submit_alt, submit, "Submit")
  win:map(keys.abort, function()
    vim.bo[win.buf].modified = false
    win:close()
  end, "Abort")

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = win.buf,
    callback = submit,
  })

  -- Typed text must not vanish on a reflex `q` or `<Esc>`.
  vim.keymap.set("n", "q", function()
    if vim.bo[win.buf].modified then
      log.warn(("Comment not sent — %s to submit, %s to discard"):format(keys.submit, keys.abort))
    else
      win:close()
    end
  end, { buffer = win.buf, nowait = true, silent = true })
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = win.buf })

  vim.cmd("startinsert")
  pcall(vim.api.nvim_win_set_cursor, win.win, { #lines, 0 })
  return win
end

return M
