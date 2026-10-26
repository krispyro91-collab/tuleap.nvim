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

describe("returning to the picker", function()
  if not pcall(require, "telescope.pickers") then
    pending("telescope.nvim is not installed")
    return
  end

  local client = require("tuleap.api.client")
  local config = require("tuleap.config")
  local original_request

  ---@return integer? bufnr of the open Telescope prompt
  local function prompt_buffer()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "TelescopePrompt" then
        return buf
      end
    end
  end

  --- Open the picker, filter it with `prompt`, open the selection and close
  --- the artifact view again.
  ---@param prompt string
  ---@param opts tuleap.PickerOpts? defaults to two pre-fetched artifacts
  ---@return integer? bufnr of the prompt after the view closed, if any
  local function view_and_close(prompt, opts)
    local other = vim.tbl_extend("force", vim.deepcopy(fixtures.artifact), {
      id = 1300,
      xref = "bug #1300",
      title = "Unrelated crash in the exporter",
    })
    pickers.artifacts(opts or { artifacts = { fixtures.artifact, other } })
    assert.is_true(vim.wait(2000, function()
      return prompt_buffer() ~= nil
    end, 10), "the picker never opened")

    local bufnr = prompt_buffer()
    local picker = require("telescope.actions.state").get_current_picker(bufnr)
    picker:set_prompt(prompt)
    vim.wait(500, function()
      return false
    end, 10)
    require("telescope.actions").select_default(bufnr)

    local view
    assert.is_true(vim.wait(2000, function()
      view = vim.api.nvim_get_current_win()
      return prompt_buffer() == nil and vim.api.nvim_win_get_config(view).relative ~= ""
    end, 10), "the artifact view never opened")
    vim.api.nvim_win_close(view, true)

    vim.wait(2000, function()
      return prompt_buffer() ~= nil
    end, 10)
    return prompt_buffer()
  end

  before_each(function()
    original_request = client.request
    client.request = function(_, cb)
      vim.schedule(function()
        cb("HTTP 404: offline")
      end)
    end
  end)

  after_each(function()
    client.request = original_request
    local bufnr = prompt_buffer()
    if bufnr then
      require("telescope.actions").close(bufnr)
    end
    config.options.picker.return_to_picker = true
  end)

  it("reopens it with the same filter once the artifact view is closed", function()
    local bufnr = view_and_close("SSO")
    assert.is_not_nil(bufnr, "the picker did not come back")
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    assert.is_true(line:find("SSO", 1, true) ~= nil, ("prompt is %q"):format(line))
  end)

  ---@param bufnr integer prompt of the reopened picker
  ---@return table? artifact the picker holds for `id`
  local function shown(bufnr, id)
    local picker = require("telescope.actions.state").get_current_picker(bufnr)
    for _, entry in ipairs(picker.finder.results or {}) do
      if entry.value.id == id then
        return entry.value
      end
    end
  end

  local edited = vim.tbl_extend("force", vim.deepcopy(fixtures.artifact), {
    status = "Fixed",
    is_open = false,
  })

  it("runs the source again once the artifact view is closed", function()
    local runs = 0
    local bufnr = view_and_close("SSO", {
      artifacts = { fixtures.artifact },
      source = function(cb)
        runs = runs + 1
        cb(nil, { edited })
      end,
    })
    assert.is_not_nil(bufnr, "the picker did not come back")
    assert.equals(1, runs)
    assert.equals("Fixed", require("tuleap.api.artifacts").status(shown(bufnr, edited.id)))
  end)

  it("re-reads a static list once the artifact view is closed", function()
    client.request = function(opts, cb)
      vim.schedule(function()
        if opts.path == ("/artifacts/%d"):format(edited.id) then
          return cb(nil, edited, { status = 200, headers = {} })
        end
        cb("HTTP 404: offline")
      end)
    end
    local bufnr = view_and_close("SSO", { artifacts = { fixtures.artifact } })
    assert.is_not_nil(bufnr, "the picker did not come back")
    assert.equals("Fixed", require("tuleap.api.artifacts").status(shown(bufnr, edited.id)))
  end)

  it("stays closed when return_to_picker is off", function()
    config.options.picker.return_to_picker = false
    assert.is_nil(view_and_close("SSO"))
  end)
end)
