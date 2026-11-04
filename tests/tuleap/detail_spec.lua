local client = require("tuleap.api.client")
local detail = require("tuleap.ui.detail")

local fixtures = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/init.lua")

local ROUTES = {
  ["^/artifacts/%d+$"] = function()
    return fixtures.artifact
  end,
  ["^/artifacts/%d+/changesets$"] = function()
    return fixtures.changesets
  end,
  ["^/trackers/%d+$"] = function()
    return fixtures.tracker
  end,
}

---@return fun() restore
local function stub()
  local original = client.request
  client.request = function(opts, cb)
    for pattern, payload in pairs(ROUTES) do
      if opts.path:match(pattern) then
        return vim.schedule(function()
          cb(nil, payload(), { status = 200, headers = {} })
        end)
      end
    end
    vim.schedule(function()
      cb("HTTP 404: no stub for " .. opts.path)
    end)
  end
  return function()
    client.request = original
  end
end

--- Open the detail view and wait for it to finish drawing.
---@return table win
local function open()
  local win = detail.open(1234)
  vim.wait(2000, function()
    return #win:get_lines() > 10 and win.anchors ~= nil
  end, 20)
  vim.wait(200, function()
    return false
  end)
  return win
end

describe("detail view anchors", function()
  local restore

  before_each(function()
    require("tuleap.cache").invalidate()
    restore = stub()
  end)

  after_each(function()
    restore()
    require("tuleap.cache").invalidate()
  end)

  it("anchors every row of a comment to its changeset", function()
    local win = open()
    local lines = win:get_lines()

    local anchored = {}
    for row, anchor in pairs(win.anchors or {}) do
      if anchor.key == "comment" then
        anchored[anchor.value] = (anchored[anchor.value] or 0) + 1
      end
    end

    -- Both fixture comments must be reachable...
    assert.is_not_nil(anchored[1], "first comment not anchored")
    assert.is_not_nil(anchored[2], "second comment not anchored")
    -- ...and over more than just the author line, so the cursor can sit in
    -- the body and still be understood as "this comment".
    assert.is_true(anchored[1] >= 2, "comment anchored on too few rows")

    -- The anchored row really is where that comment is drawn.
    for row, anchor in pairs(win.anchors or {}) do
      if anchor.key == "comment" and anchor.value == 1 then
        local line = lines[row + 1] or ""
        assert.is_true(
          line:find("Alice", 1, true) ~= nil or line:find("Reproduced", 1, true) ~= nil,
          ("row %d is not part of the first comment: %q"):format(row, line)
        )
      end
    end
    win:close()
  end)

  it("does not anchor the header or the field rows", function()
    local win = open()
    for row = 0, 5 do
      local anchor = (win.anchors or {})[row]
      assert.is_true(
        anchor == nil or anchor.key ~= "comment",
        ("header row %d should not be a comment"):format(row)
      )
    end
    win:close()
  end)
end)

describe("detail view epic and sprint", function()
  local config = require("tuleap.config")
  local original, saved

  before_each(function()
    require("tuleap.cache").invalidate()
    saved = { project_id = config.state.project_id, epic = config.options.trackers.epic }
    config.state.project_id = 101
    config.options.trackers.epic = "epic"

    local artifact = vim.deepcopy(fixtures.artifact)
    table.insert(artifact.values, {
      field_id = 30,
      label = "Links",
      type = "art_link",
      links = {},
      reverse_links = { { id = 42, type = "_is_child" }, { id = 556 } },
    })
    table.insert(artifact.values, {
      field_id = 31,
      label = "References",
      type = "cross",
      value = { { ref = "epic #42", direction = "in" }, { ref = "task #77", direction = "out" } },
    })
    local answers = {
      ["/artifacts/77"] = {
        id = 77,
        xref = "task #77",
        tracker = { id = 13 },
        values = { { field_id = 1, type = "string", label = "Title", value = "Harden the cookie" } },
      },
      ["/artifacts/1234"] = artifact,
      ["/artifacts/1234/changesets"] = {},
      ["/artifacts/42"] = {
        id = 42,
        xref = "epic #42",
        title = "Single sign-on",
        tracker = { id = 8 },
      },
      ["/trackers/7"] = fixtures.tracker,
      ["/projects/101/trackers"] = { { id = 8, item_name = "epic", label = "Epics" } },
      ["/projects/101/milestones"] = { { id = 500, label = "Release 1.2" } },
      ["/milestones/500/milestones"] = {
        {
          id = 556,
          label = "Sprint 43",
          start_date = "2026-11-05T00:00:00+01:00",
          end_date = "2026-11-19T00:00:00+01:00",
        },
      },
    }
    original = client.request
    client.request = function(opts, cb)
      vim.schedule(function()
        local answer = answers[opts.path]
        if answer == nil then
          return cb("HTTP 404: no stub for " .. opts.path)
        end
        cb(nil, answer, { status = 200, headers = {} })
      end)
    end
  end)

  after_each(function()
    client.request = original
    config.state.project_id = saved.project_id
    config.options.trackers.epic = saved.epic
    require("tuleap.cache").invalidate()
  end)

  it("shows both under the tracker, anchored to their artifacts", function()
    local win = detail.open(1234)
    local epic_row, sprint_row
    vim.wait(2000, function()
      for row, line in ipairs(win:get_lines()) do
        if line:find("Epic%s+epic #42  Single sign%-on") then
          epic_row = row - 1
        elseif line:find("Sprint%s+Sprint 43 · 05/11/2026 → 19/11/2026") then
          sprint_row = row - 1
        end
      end
      return epic_row ~= nil and sprint_row ~= nil
    end, 20)

    assert.is_not_nil(epic_row, "no Epic row")
    assert.is_not_nil(sprint_row, "no Sprint row")
    assert.same({ key = "artifact", value = 42 }, win.anchors[epic_row])
    assert.same({ key = "artifact", value = 556 }, win.anchors[sprint_row])
    win:close()
  end)

  it("lists the references with their titles, under no repeated header", function()
    local win = detail.open(1234)
    local task_row
    vim.wait(2000, function()
      for row, line in ipairs(win:get_lines()) do
        if line:find("task #77  Harden the cookie", 1, true) then
          task_row = row - 1
        end
      end
      return task_row ~= nil
    end, 20)

    assert.is_not_nil(task_row, "no titled reference row")
    assert.same({ key = "artifact", value = 77 }, win.anchors[task_row])
    local text = table.concat(win:get_lines(), "\n")
    assert.truthy(text:find("epic #42  Single sign-on", 1, true))
    assert.falsy(text:find("bug #1234", 1, true))
    win:close()
  end)

  it("opens the reference under the cursor on <CR>", function()
    local win = detail.open(1234)
    local task_row
    vim.wait(2000, function()
      for row, line in ipairs(win:get_lines()) do
        if line:find("task #77  Harden the cookie", 1, true) then
          task_row = row
        end
      end
      return task_row ~= nil
    end, 20)
    assert.is_not_nil(task_row, "no titled reference row")

    vim.api.nvim_win_set_cursor(win.win, { task_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    local opened
    vim.wait(2000, function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local title = (vim.api.nvim_win_get_config(w).title or {})[1]
        if title and title[1]:find("task #77", 1, true) then
          opened = w
        end
      end
      return opened ~= nil
    end, 20)
    assert.is_false(win:valid(), "the epic view should give way to the reference")
    assert.is_not_nil(opened, "the reference was not opened")
    vim.api.nvim_win_close(opened, true)
  end)
end)

describe("edit form sections", function()
  local config = require("tuleap.config")
  local restore

  before_each(function()
    require("tuleap.cache").invalidate()
    restore = stub()
  end)

  after_each(function()
    restore()
    require("tuleap.cache").invalidate()
  end)

  --- Drive the real edit action and return the form buffer's headings.
  ---@return string[]
  local function headings()
    require("tuleap.actions").edit(1234)
    vim.wait(2000, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "markdown" then
          for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if line:match("^###%s") then
              return true
            end
          end
        end
      end
      return false
    end, 20)

    local found = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "markdown" then
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          if line:match("^###%s") then
            found[#found + 1] = vim.trim(line)
          end
        end
        vim.bo[buf].modified = false
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    return found
  end

  it("offers no empty Comment section by default", function()
    local found = headings()
    assert.is_true(#found > 0, "the edit form had no sections at all")
    for _, heading in ipairs(found) do
      assert.is_not.equals("### Comment", heading)
    end
  end)

  it("offers one when comment_on_edit is enabled", function()
    local previous = config.options.ui.comment_on_edit
    config.options.ui.comment_on_edit = true
    local found = headings()
    assert.is_true(vim.tbl_contains(found, "### Comment"))
    config.options.ui.comment_on_edit = previous
  end)
end)

describe("detail view with render-markdown.nvim", function()
  local config = require("tuleap.config")
  local restore, rendered

  before_each(function()
    require("tuleap.cache").invalidate()
    restore = stub()
    rendered = {}
    package.loaded["render-markdown"] = {
      render = function(ctx)
        rendered[#rendered + 1] = ctx
      end,
    }
  end)

  after_each(function()
    package.loaded["render-markdown"] = nil
    config.options.ui.render_markdown = true
    restore()
    require("tuleap.cache").invalidate()
  end)

  it("keeps the markdown source and hands the buffer to the plugin", function()
    local win = open()
    local text = table.concat(win:get_lines(), "\n")
    assert.truthy(text:find("**SAML**", 1, true), "description lost its markdown")
    assert.truthy(text:find("\n  Reproduced on staging", 1, true), "comment body must not be a code block")
    assert.truthy(text:find("`fix/sso-loop`", 1, true), "HTML comment not turned into markdown")
    assert.is_true(#rendered > 0)
    assert.equals(win.buf, rendered[#rendered].buf)
    win:close()
  end)

  it("renders once the redraws settle, with render-markdown's throttle off", function()
    -- Regression: the view redraws as each request answers. render-markdown
    -- drops a request that follows another within its `debounce` window, so
    -- the final content stayed raw while the earlier marks piled up at the
    -- end of the buffer.
    local win = open()
    assert.equals(1, #rendered, "the burst of redraws must render once")
    assert.equals(0, rendered[1].config.debounce)
    win:close()
  end)

  it("stays plain when disabled", function()
    config.options.ui.render_markdown = false
    local win = open()
    local text = table.concat(win:get_lines(), "\n")
    assert.falsy(text:find("**SAML**", 1, true))
    assert.equals(0, #rendered)
    win:close()
  end)
end)
