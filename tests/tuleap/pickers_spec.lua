local pickers = require("tuleap.pickers")

local fixtures =
  dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

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
    local text = table.concat(
      vim.tbl_map(function(column)
        return column[1]
      end, columns),
      " "
    )
    assert.is_true(text:find("9", 1, true) ~= nil)
  end)
end)

describe("sprint and epic names", function()
  local parents = {
    epic = { id = 42, xref = "epic #42", title = "Single sign-on" },
    sprint = {
      id = 556,
      label = "Sprint 43",
      start_date = "2026-11-05T00:00:00+01:00",
      end_date = "2026-11-19T00:00:00+01:00",
    },
  }

  ---@param columns {[1]: string, [2]: string}[]
  ---@return string[]
  local function texts(columns)
    return vim.tbl_map(function(column)
      return column[1]
    end, columns)
  end

  it("adds a sprint and an epic column before the title", function()
    local columns = texts(pickers.entry_columns(fixtures.artifact, parents))
    assert.equals("Sprint 43", columns[#columns - 2])
    assert.equals("Single sign-on", columns[#columns - 1])
    assert.equals("SSO redirect loops on first login", columns[#columns])
  end)

  it("keeps the columns aligned for a row with no parents", function()
    local shown = { sprint = true, epic = true }
    local with = pickers.entry_columns(fixtures.artifact, parents, shown)
    local without = pickers.entry_columns(fixtures.artifact, nil, shown)
    assert.equals(#with, #without)
    assert.equals("", without[#without - 1][1])
  end)

  it("leaves both columns out when not asked for", function()
    local plain = pickers.entry_columns(fixtures.artifact)
    assert.equals(#plain, #pickers.entry_columns(fixtures.artifact, nil))
    assert.is_false(vim.tbl_contains(texts(plain), "Sprint 43"))
  end)

  it("makes the sprint and epic names searchable", function()
    local ordinal = pickers.entry_ordinal(fixtures.artifact, parents)
    assert.truthy(ordinal:find("Sprint 43", 1, true))
    assert.truthy(ordinal:find("Single sign-on", 1, true))
  end)

  it("carries the parents on each entry", function()
    local make = pickers.entry_maker({ fixtures.artifact }, { [fixtures.artifact.id] = parents })
    assert.equals(parents, make(fixtures.artifact).parents)
  end)

  it("names them in the preview instead of listing bare link ids", function()
    local artifact = vim.deepcopy(fixtures.artifact)
    table.insert(artifact.values, {
      field_id = 30,
      label = "Links",
      type = "art_link",
      links = { { id = 777 } },
      reverse_links = { { id = 42 } },
    })
    local text = table.concat(pickers.artifact_preview(artifact, 80, false, parents).lines, "\n")
    assert.truthy(text:find("Epic%s+epic #42  Single sign%-on"), text)
    assert.truthy(text:find("Sprint%s+Sprint 43 · 05/11/2026 → 19/11/2026"), text)
    assert.is_nil(text:find("777", 1, true), "link ids must not be listed")
  end)
end)

describe("picker order", function()
  ---@param id integer
  ---@param status string
  ---@param is_open boolean
  local function epic(id, status, is_open)
    return { id = id, status = status, is_open = is_open }
  end

  ---@param list table[]
  ---@return integer[]
  local function ids(list)
    return vim.tbl_map(function(item)
      return item.id
    end, list)
  end

  it("puts open epics first, then planned ones, then closed ones, newest first", function()
    local list = {
      epic(1, "Closed", false),
      epic(2, "Open", true),
      epic(3, "Planned", false),
      epic(4, "Open", true),
      epic(5, "Closed", false),
      epic(6, "Planned", false),
    }
    assert.same({ 4, 2, 6, 3, 5, 1 }, ids(pickers.sort_by_status(list)))
  end)

  it("only sorts by id when the status does not matter", function()
    local list = { epic(1, "Open", true), epic(3, "Closed", false), epic(2, "Planned", false) }
    assert.same({ 3, 2, 1 }, ids(pickers.sort_by_status(list, false)))
  end)

  it("follows a workflow: in review, in progress, todo, done, cancelled", function()
    local list = {
      epic(1, "Done", false),
      epic(2, "Todo", true),
      epic(3, "In Review", true),
      epic(4, "In progress", true),
      epic(5, "Canceled", false),
      epic(6, "To do", true),
      epic(7, "Blocked", true),
      epic(8, "Rejected", false),
      epic(9, "Cancelled", false),
    }
    local order = { "review", "progress", "todo", "done", "cancel" }
    assert.same({ 3, 4, 6, 2, 7, 1, 9, 5, 8 }, ids(pickers.sort_by_status(list, order)))
  end)

  it("puts other open statuses after the whole workflow when it names no done one", function()
    local list = { epic(1, "Done", false), epic(2, "Blocked", true), epic(3, "Todo", true) }
    assert.same({ 3, 2, 1 }, ids(pickers.sort_by_status(list, { "todo" })))
  end)

  it("lists the latest sprint first", function()
    local list = { { id = 1 }, { id = 2 }, { id = 3 } }
    assert.same({ 3, 2, 1 }, ids(pickers.latest_first(list)))
    assert.same({ 1, 2, 3 }, ids(list))
  end)

  it("leaves hidden parent columns out of the rows but not of the preview", function()
    local parents = { sprint = { id = 556, label = "Sprint 43" } }
    local make = pickers.entry_maker(
      { fixtures.artifact },
      { [fixtures.artifact.id] = parents },
      { sprint = true }
    )
    local entry = make(fixtures.artifact)
    assert.is_nil(entry.ordinal:find("Sprint 43", 1, true))
    assert.equals(parents, entry.parents)
  end)
end)

describe("pickers.milestone_content", function()
  local client = require("tuleap.api.client")
  local original_request, original_artifacts, opened

  before_each(function()
    require("tuleap.cache").invalidate()
    original_request, original_artifacts, opened = client.request, pickers.artifacts, nil
    client.request = function(opts, cb)
      local answers = {
        ["/milestones/556"] = { id = 556, label = "Sprint 43" },
        ["/milestones/556/content"] = { fixtures.artifact },
      }
      vim.schedule(function()
        cb(nil, answers[opts.path], { status = 200, headers = {} })
      end)
    end
    pickers.artifacts = function(opts)
      opened = opts
    end
  end)

  after_each(function()
    client.request, pickers.artifacts = original_request, original_artifacts
    require("tuleap.cache").invalidate()
  end)

  ---@param label string?
  ---@return string? title
  local function title_for(label)
    pickers.milestone_content(556, label)
    vim.wait(2000, function()
      return opened ~= nil
    end, 5)
    return opened and opened.title
  end

  it("names the sprint in the title, not its id", function()
    assert.equals("Sprint 43 content", title_for())
  end)

  it("uses the name it is given without asking for it", function()
    assert.equals("Release 1.2 content", title_for("Release 1.2"))
  end)

  it("leaves the sprint column out, every row being in that sprint", function()
    title_for("Sprint 43")
    assert.same({ sprint = true }, opened.hide)
  end)
end)

describe("pickers.milestone_entry", function()
  it("shows the period with the year, searchable too", function()
    local entry = pickers.milestone_entry({
      id = 556,
      label = "Sprint 43",
      semantic_status = "Open",
      start_date = "2026-11-05T00:00:00+01:00",
      end_date = "2026-11-19T00:00:00+01:00",
    })
    assert.truthy(entry.display:find("05/11/2026 → 19/11/2026", 1, true), entry.display)
    assert.truthy(entry.ordinal:find("2026", 1, true))
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
    assert.is_true(
      vim.wait(2000, function()
        return prompt_buffer() ~= nil
      end, 10),
      "the picker never opened"
    )

    local bufnr = prompt_buffer()
    local picker = require("telescope.actions.state").get_current_picker(bufnr)
    picker:set_prompt(prompt)
    vim.wait(500, function()
      return false
    end, 10)
    require("telescope.actions").select_default(bufnr)

    local view
    assert.is_true(
      vim.wait(2000, function()
        view = vim.api.nvim_get_current_win()
        return prompt_buffer() == nil and vim.api.nvim_win_get_config(view).relative ~= ""
      end, 10),
      "the artifact view never opened"
    )
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

  it("opens before the data arrives and fills in once it does", function()
    local answer
    pickers.artifacts({
      title = "Streaming",
      source = function(cb)
        answer = cb
      end,
    })
    assert.is_true(
      vim.wait(2000, function()
        return prompt_buffer() ~= nil
      end, 10),
      "the picker waited for the data"
    )
    assert.is_function(answer)
    local bufnr = prompt_buffer()
    assert.is_nil(shown(bufnr, fixtures.artifact.id))

    answer(nil, { fixtures.artifact })
    assert.is_true(
      vim.wait(2000, function()
        return shown(bufnr, fixtures.artifact.id) ~= nil
      end, 10),
      "the rows never showed up"
    )
  end)

  it("ignores data that arrives after the picker was closed", function()
    local answer
    pickers.artifacts({
      source = function(cb)
        answer = cb
      end,
    })
    assert.is_true(
      vim.wait(2000, function()
        return prompt_buffer() ~= nil
      end, 10),
      "the picker never opened"
    )
    require("telescope.actions").close(prompt_buffer())
    vim.wait(100, function()
      return false
    end, 10)

    local ok, err = pcall(answer, nil, { fixtures.artifact })
    assert.is_true(ok, err)
    vim.wait(100, function()
      return false
    end, 10)
    assert.is_nil(prompt_buffer(), "a closed picker came back")
  end)

  it("stays closed when return_to_picker is off", function()
    config.options.picker.return_to_picker = false
    assert.is_nil(view_and_close("SSO"))
  end)
end)
