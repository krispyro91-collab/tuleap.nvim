---@mod tuleap.config Configuration and credential resolution
---
--- Credentials are never stored in the plugin spec. They are read from the
--- environment (`TULEAP_URL` / `TULEAP_TOKEN` by default) or produced by an
--- external command (`token_cmd`) so they can come from pass, gopass, 1password,
--- `secret-tool`, ...

local log = require("tuleap.util.log")

local M = {}

---@class tuleap.Config
local defaults = {
  --- Base URL of the Tuleap instance, e.g. "https://tuleap.example.com".
  --- When nil, read from the environment variable named by `env.url`.
  ---@type string?
  url = nil,

  --- Personal access key (`tlp-k1-...`). Prefer leaving this nil and exporting
  --- the environment variable instead; a token in a dotfile is a token in git.
  ---@type string?
  token = nil,

  --- Names of the environment variables holding the connection settings.
  env = {
    url = "TULEAP_URL",
    token = "TULEAP_TOKEN",
  },

  --- Optional command printing the token on stdout, used when neither `token`
  --- nor the environment variable is set. Example:
  ---   token_cmd = { "pass", "show", "tuleap/token" }
  ---@type string[]|string|nil
  token_cmd = nil,

  --- Default project: numeric id, or shortname as a string. When nil the first
  --- command needing a project opens the project picker and remembers the pick.
  ---@type integer|string|nil
  project = nil,

  --- Maps the plugin's vocabulary onto your Tuleap trackers.
  ---
  --- A value is a numeric tracker id, a name, or a list of candidate names
  --- tried in order. Names are matched against both the tracker shortname
  --- (`item_name`) and its label, ignoring case, punctuation and plurals — so
  --- `story` finds a tracker labelled "User Stories".
  ---
  --- Tuleap's project templates disagree on what the issue tracker is called,
  --- hence the candidate lists. Unknown keys are allowed and become available
  --- as `:Tuleap list <key>`.
  trackers = {
    issue = { "issue", "bug" },
    epic = "epic",
    story = { "story", "user story" },
    task = "task",
    sprint = "sprint",
    release = "release",
  },

  --- Fields this plugin acts on by role, when no tracker semantic names them.
  ---
  --- A value is a numeric field id, a name, or a list of candidates tried in
  --- order. Names are matched against both the field name and its label,
  --- ignoring case, punctuation and plurals — so `involved` finds a field
  --- labelled "Involved users". Set a role to false to disable it.
  fields = {
    --- The users involved in an artifact, beside its assignee. Tuleap has no
    --- semantic for that one, so it is found by name;
    --- `:Tuleap involve` / `:Tuleap uninvolve` add and remove a single user
    --- on it.
    ---@type string|integer|string[]|false
    involved = { "involved_users", "involved" },
  },

  --- Artifact hierarchy.
  links = {
    --- Link nature used when attaching an artifact under a parent. `_is_child`
    --- is Tuleap's built-in parent/child nature, used by the Agile Dashboard
    --- hierarchy. Change it if your instance models the hierarchy with a
    --- custom nature.
    parent_nature = "_is_child",
  },

  --- HTTP behaviour.
  request = {
    timeout = 20000, -- ms
    insecure = false, -- pass --insecure to curl (self-signed instances)
    proxy = nil, ---@type string?
    per_page = 100, -- Tuleap caps most collections at 100
    max_pages = 20, -- safety net for `paginate`
    extra_headers = {}, ---@type table<string,string>
  },

  --- In-memory caching of immutable-ish metadata (projects, tracker schemas).
  --- Artifact payloads are cached too but invalidated on every write.
  cache = {
    enabled = true,
    ttl = 300, -- seconds
  },

  --- Floating window / view appearance.
  ui = {
    border = "rounded",
    width = 0.85, -- fraction of the editor, or absolute columns when > 1
    height = 0.85,
    winblend = 0,

    --- Stacking order of the plugin's floating windows.
    ---
    --- Deliberately below 50, the value Neovim gives a float that asks for
    --- nothing — which is what nvim-notify's windows get. Among floats
    --- sharing a zindex the *focused* one is drawn on top, so a panel at 50
    --- hides the notifications that appear while it is open.
    ---
    --- For reference: noice `hover` 45, nvim-notify 50, noice `mini` 60,
    --- snacks notifier 100, noice cmdline 200.
    zindex = 45,
    --- Show a one-line hint of the buffer-local mappings under the title.
    show_help_hint = true,
    --- Which tracker fields the create/edit form offers:
    ---   "common"   required fields + title/description/status/assignee/effort
    ---   "required" required fields only
    ---   "all"      every writable field of the tracker
    form_fields = "common",
    --- How rich text fields are presented for editing:
    ---   "commonmark" edit Tuleap's markdown source when it exposes one
    ---   "preserve"   edit the stored source as-is, in its own format
    --- Either way the field's format is sent back unchanged — a description
    --- stored as HTML is never silently downgraded to plain text.
    text_format = "commonmark",
    --- Offer a "Comment" section in the edit form, to attach a follow-up
    --- comment to the same change. Off by default: an empty section reads as
    --- if it should be showing the existing comments. Add comments with the
    --- dedicated action instead (`c` in the artifact view).
    comment_on_edit = false,
    --- Render descriptions and comments with render-markdown.nvim when it is
    --- installed. Set to false to keep the plain, re-wrapped text.
    render_markdown = true,
    icons = {
      epic = "󰓾",
      story = "󰈙",
      bug = "",
      task = "",
      sprint = "󰁪",
      release = "󰏗",
      open = "",
      closed = "",
      comment = "󰅺",
      user = "",
      date = "",
      effort = "󰓹",
    },
  },

  --- Terminal chart rendering (burndown / burnup).
  chart = {
    --- "braille" (2x4 dots per cell, highest resolution), "blocks" (half
    --- blocks, safest with most fonts) or "ascii" (no Unicode at all).
    style = "braille",
    --- Plot height in text rows. Width defaults to the available window width.
    height = 18,
    ---@type integer?
    width = nil,
    --- Draw the dashed "ideal" guideline on burndown charts.
    show_ideal = true,
    --- Draw today's vertical marker.
    show_today = true,
    --- Highlight groups per series slot; see |tuleap-highlights|.
    colors = {
      "TuleapChartSeries1",
      "TuleapChartSeries2",
      "TuleapChartSeries3",
      "TuleapChartSeries4",
    },
  },

  --- Telescope picker tweaks merged into every picker this plugin opens.
  picker = {
    ---@type table
    opts = {},
    --- Preview the artifact body in the picker.
    preview = true,
    --- Show the artifact id column.
    show_id = true,
  },

  --- Buffer-local mappings inside Tuleap views. Set a value to false to unmap.
  keymaps = {
    detail = {
      close = "q",
      refresh = "r",
      edit = "e",
      comment = "c",
      close_artifact = "x",
      involve = "i",
      uninvolve = "I",
      attach = "A",
      delete = "D",
      open_browser = "o",
      yank_url = "y",
      help = "g?",
      links = "L",
    },
    form = {
      submit = "<C-s>",
      submit_alt = "ZZ",
      abort = "ZQ",
      pick_value = "<CR>",
      help = "g?",
    },
    chart = {
      close = "q",
      refresh = "r",
      toggle = "t", -- switch burndown <-> burnup
      content = "c", -- open the sprint backlog picker
      open_browser = "o",
      help = "g?",
    },
  },

  --- "trace" | "debug" | "info" | "warn" | "error" | "off"
  log_level = "info",
}

---@type tuleap.Config
M.options = nil

--- Runtime state that survives across commands but not across sessions.
M.state = {
  ---@type integer?
  project_id = nil,
  ---@type string?
  project_label = nil,
  ---@type integer?
  last_artifact_id = nil,
  ---@type integer?
  last_milestone_id = nil,
  --- Last TQL query, reused as the default of the next search.
  ---@type string?
  last_query = nil,
}

---@param cmd string[]|string
---@return string?
local function run_token_cmd(cmd)
  local out = vim.system(type(cmd) == "table" and cmd or { "sh", "-c", cmd }, { text = true }):wait()
  if out.code ~= 0 then
    log.error("token_cmd failed (exit %d): %s", out.code, vim.trim(out.stderr or ""))
    return nil
  end
  local token = vim.trim(out.stdout or "")
  return token ~= "" and token or nil
end

--- Resolve the instance URL, trimming any trailing slash and `/api` suffix so
--- both "https://host" and "https://host/api/" behave identically.
---@return string?
function M.url()
  local url = M.options.url or vim.env[M.options.env.url]
  if not url or url == "" then
    return nil
  end
  url = vim.trim(url):gsub("/+$", "")
  url = url:gsub("/api/?v?%d*$", "")
  return url
end

local cached_token = nil

--- Resolve the personal access key.
---@return string?
function M.token()
  if cached_token then
    return cached_token
  end
  local token = M.options.token or vim.env[M.options.env.token]
  if (not token or token == "") and M.options.token_cmd then
    token = run_token_cmd(M.options.token_cmd)
  end
  if not token or token == "" then
    return nil
  end
  cached_token = vim.trim(token)

  -- A secret store that was written twice ends up holding the key twice,
  -- concatenated. Tuleap then rejects the whole string with "Key or token
  -- incorrectly formatted", which says nothing about the real cause.
  local _, occurrences = cached_token:gsub("tlp%-k1%-", "")
  if occurrences > 1 then
    local second = cached_token:find("tlp%-k1%-", 2)
    log.warn(
      "$%s contains %d access keys concatenated; using the first.\n"
        .. "Re-encrypt it with a single key to silence this.",
      M.options.env.token,
      occurrences
    )
    if second then
      cached_token = cached_token:sub(1, second - 1)
    end
  end

  return cached_token
end

--- Forget a token obtained through `token_cmd` (used by `:Tuleap refresh`).
function M.forget_token()
  cached_token = nil
end

--- True when both URL and token are available.
---@return boolean ok
---@return string? err human readable reason
function M.validate()
  if not M.url() then
    return false,
      ("No Tuleap URL. Export $%s or set `url` in the plugin options."):format(M.options.env.url)
  end
  if not M.token() then
    return false,
      ("No Tuleap access key. Export $%s (a `tlp-k1-...` personal access key)."):format(
        M.options.env.token
      )
  end
  return true
end

---@param opts tuleap.Config?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- `trackers` is a mapping, not a list: a user-provided table must replace the
  -- defaults wholesale when they say so, otherwise our defaults leak in.
  if opts and opts.trackers and opts.trackers.__replace then
    M.options.trackers = vim.deepcopy(opts.trackers)
    M.options.trackers.__replace = nil
  end

  if M.options.project then
    if type(M.options.project) == "number" then
      M.state.project_id = M.options.project
    end
  end
  return M.options
end

M.defaults = defaults

return M
