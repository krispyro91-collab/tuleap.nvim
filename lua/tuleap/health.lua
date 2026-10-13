---@mod tuleap.health :checkhealth tuleap

local M = {}

local function start(name)
  (vim.health.start or vim.health.report_start)(name)
end
local function ok(msg)
  (vim.health.ok or vim.health.report_ok)(msg)
end
local function warn(msg, advice)
  (vim.health.warn or vim.health.report_warn)(msg, advice)
end
local function err(msg, advice)
  (vim.health.error or vim.health.report_error)(msg, advice)
end
local function info(msg)
  (vim.health.info or vim.health.report_info)(msg)
end

function M.check()
  local config = require("tuleap.config")
  if not config.options then
    config.setup({})
  end

  start("tuleap.nvim: dependencies")
  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    err("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("curl") == 1 then
    ok("curl found")
  else
    err("curl is not in $PATH", { "Install curl: plenary.curl shells out to it." })
  end

  for _, plugin in ipairs({ "plenary", "telescope" }) do
    if pcall(require, plugin) then
      ok(plugin .. ".nvim found")
    else
      err(plugin .. ".nvim is missing", { "Add it to the plugin dependencies." })
    end
  end

  start("tuleap.nvim: connection")
  local url = config.url()
  if url then
    ok("URL: " .. url)
  else
    err(("No instance URL ($%s is unset)"):format(config.options.env.url), {
      ("export %s=https://tuleap.example.com"):format(config.options.env.url),
    })
  end

  local token = config.token()
  if token then
    if token:match("^tlp%-k1%-") then
      ok("Access key looks like a personal access key (tlp-k1-…)")
    else
      warn("The token does not start with `tlp-k1-`", {
        "tuleap.nvim authenticates with X-Auth-AccessKey, which expects a",
        "personal access key created from your Tuleap account preferences.",
      })
    end
  else
    err(("No access key ($%s is unset)"):format(config.options.env.token), {
      ("export %s=tlp-k1-…"):format(config.options.env.token),
      "Create one in Tuleap: avatar → Preferences → Keys & tokens.",
    })
  end

  if not url or not token then
    return
  end

  start("tuleap.nvim: API")
  local client = require("tuleap.api.client")
  local request_err, me = client.get_sync("/users/self", 10000)
  if request_err then
    err("GET /api/v1/users/self failed: " .. request_err, {
      "Check the URL, the access key scopes and any proxy settings.",
      "Self-signed certificate? set `request.insecure = true`.",
    })
  else
    ok(("Authenticated as %s"):format(require("tuleap.api.users").label(me)))
  end

  local project_err, projects = client.get_sync("/projects?limit=1", 10000)
  if project_err then
    warn("Could not list projects: " .. project_err)
  else
    info(("Projects reachable: %d returned on the first page"):format(#(projects or {})))
  end

  start("tuleap.nvim: configuration")
  info(("Project: %s"):format(
    config.state.project_label
      or (config.state.project_id and ("#" .. config.state.project_id))
      or tostring(config.options.project or "not selected")
  ))
  local mapped = {}
  for key, value in pairs(config.options.trackers) do
    mapped[#mapped + 1] = ("%s → %s"):format(key, tostring(value))
  end
  table.sort(mapped)
  info("Tracker mapping: " .. table.concat(mapped, ", "))
  info(("Chart style: %s"):format(config.options.chart.style))
  info(("Debug log: %s"):format(require("tuleap.util.log").logfile()))
end

return M
