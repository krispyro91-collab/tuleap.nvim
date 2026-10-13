-- Render every Tuleap view against canned payloads, without a live instance.
--
--   nvim --headless -u NONE -l tests/preview.lua [detail|sprint|chart|form]
--
-- Each view is drawn into a real floating window and then dumped to stdout, so
-- this catches layout and highlight regressions in CI as well as by eye.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.o.columns, vim.o.lines = 100, 40

local fixtures = dofile(root .. "/tests/fixtures/init.lua")

require("tuleap").setup({ url = "https://tuleap.example.com", token = "tlp-k1-fake", project = 101 })

-- Stub the transport: every route answers from the fixtures.
local client = require("tuleap.api.client")
local routes = {
  ["^/users/self$"] = fixtures.user,
  ["^/artifacts/%d+$"] = fixtures.artifact,
  ["^/artifacts/%d+/changesets$"] = fixtures.changesets,
  ["^/artifacts/%d+/linked_artifacts$"] = { collection = fixtures.links },
  ["^/trackers/%d+$"] = fixtures.tracker,
  ["^/trackers/%d+/artifacts$"] = fixtures.artifacts,
  ["^/milestones/%d+$"] = fixtures.milestone,
  ["^/milestones/%d+/burndown$"] = fixtures.burndown,
  ["^/milestones/%d+/content$"] = fixtures.artifacts,
  ["^/milestones/%d+/milestones$"] = {},
  ["^/projects/%d+/milestones$"] = fixtures.milestones,
}

client.request = function(opts, cb)
  for pattern, payload in pairs(routes) do
    if opts.path:match(pattern) then
      return vim.schedule(function()
        cb(nil, payload, { status = 200, headers = {}, total = type(payload) == "table" and #payload or nil })
      end)
    end
  end
  vim.schedule(function()
    cb(("HTTP 404: no fixture for %s"):format(opts.path))
  end)
end

---@param win table
---@param label string
local function dump(win, label)
  vim.wait(300, function()
    return false
  end)
  -- `print` swallows empty messages in headless mode, so write directly.
  io.write(("\n=== %s %s\n"):format(label, ("="):rep(math.max(0, 76 - #label))))
  for _, line in ipairs(win:get_lines()) do
    io.write(line, "\n")
  end
  local marks = vim.api.nvim_buf_get_extmarks(win.buf, require("tuleap.ui.window").ns, 0, -1, {})
  io.write(("--- %d lines, %d highlights\n"):format(#win:get_lines(), #marks))
  win:close()
end

local which = arg and arg[1] or "all"

if which == "all" or which == "detail" then
  dump(require("tuleap.ui.detail").open(1234), "artifact detail view")
end

if which == "all" or which == "sprint" then
  dump(require("tuleap.ui.sprint").open(555), "sprint dashboard (burndown + burnup)")
end

if which == "all" or which == "chart" then
  dump(require("tuleap.ui.sprint").open(555, { mode = "burndown" }), "burndown only")
end

if which == "all" or which == "form" then
  dump(
    require("tuleap.ui.form").open({
      title = "Edit bug #1234",
      fields = require("tuleap.api.trackers").editable_fields(fixtures.tracker),
      values = (function()
        local by_id = {}
        for _, value in ipairs(fixtures.artifact.values) do
          by_id[value.field_id] = value
        end
        return by_id
      end)(),
      comment = true,
      intro = { "Editing bug #1234 — SSO redirect loops on first login" },
      on_submit = function() end,
    }),
    "edit form"
  )
end

vim.cmd("qa!")
