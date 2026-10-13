# tuleap.nvim

Work with [Tuleap](https://www.tuleap.org/) from Neovim: find, list, create,
read, update, close and delete issues, epics, user stories and sprints through
the Tuleap REST API — with [Telescope](https://github.com/nvim-telescope/telescope.nvim)
pickers and **burndown / burnup charts rendered directly in the terminal**.

```
  󰁪  Sprint 42   Open
  ───────────────────────────────────────────────────────────────────────────
  Period        2026-10-04 → 2026-10-18  (14 days, 5 left)
  Effort        capacity 40  ·  planned 38  ·  remaining 11
  Progress      █████████████████████░░░░░░░░░  71%
  Content       13 artifacts  ·  9 open  ·  4 closed

  Burndown — remaining effort
40 ┤⠒ ⠤ ⠤ ⣀                                           ⠘
   │⠉⠑⠒⠒⠢⠤⠤⣀⣉⣀⠉ ⠒ ⠤ ⠤ ⣀                               ⠘
   │          ⠉⠉⠒⠒⠤⠤⣀⣀⡠⠤⠭⠔⠛⠒⠶⠤⠤⣀⣤⡀⣀                   ⠘
20 ┤                             ⠈⠉⠉⠙⠒⠛⠤⠶⠤⣤⣀⡤ ⣀       ⠘
   │                                        ⠈⠉⠑⠒⠫⠤⢍⣀⣒⡀⠼ ⠤ ⣀
 0 ┤                                                  ⠘           ⠉ ⠒ ⠤ ⣀
   └───────────────────────────────────────────────────────────────────────
    04/10       07/10          10/10         12/10          15/10     18/10
    ── Remaining   ┈┈ Ideal
```

## Features

- **Telescope pickers** for artifacts, trackers, projects and sprints, with a
  live preview of the artifact body, status and fields.
- **Full artifact lifecycle**: create, read, update, comment, close and delete —
  every write goes through a form buffer, never a one-line prompt.
- **Burndown and burnup charts** drawn with braille (2×4 dots per cell), half
  blocks or plain ASCII, with the ideal line and a "today" marker.
- **Sprint dashboard** combining period, capacity, progress bar, content
  breakdown and both charts on one screen.
- **TQL search** (`expert_query`) for server-side filtering, fuzzy matching for
  everything else.
- **No credentials in your config**: the URL and personal access key come from
  the environment or from a command of your choosing.

## Requirements

| | |
|---|---|
| Neovim | 0.10 or newer |
| [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) | HTTP transport |
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) | pickers |
| `curl` | in `$PATH` |
| Tuleap | 11 or newer (personal access keys), Agile Dashboard for sprints |

A [Nerd Font](https://www.nerdfonts.com/) is recommended for the icons, and a
font with braille coverage for the default chart style. Neither is mandatory —
see `ui.icons` and `chart.style`.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "krispyro91-collab/tuleap.nvim",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  cmd = "Tuleap",
  keys = {
    { "<leader>tul", function() require("tuleap").issues() end, desc = "Tuleap: list issues" },
    { "<leader>tus", function() require("tuleap").sprints() end, desc = "Tuleap: sprints" },
  },
  opts = {
    project = "my-project",
    trackers = { issue = "bug", epic = "epic", story = "story", sprint = "sprint" },
  },
}
```

## Connection

tuleap.nvim authenticates with a **personal access key** sent in the
`X-Auth-AccessKey` header. Create one in Tuleap under
*avatar → Preferences → Keys & tokens → Personal access keys*, granting at
least the **REST** scope.

Export both variables from your shell profile:

```bash
export TULEAP_URL="https://tuleap.example.com"
export TULEAP_TOKEN="tlp-k1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Prefer a secret manager? Leave `TULEAP_TOKEN` unset and point the plugin at a
command instead:

```lua
opts = {
  token_cmd = { "pass", "show", "tuleap/token" },
}
```

Run `:checkhealth tuleap` to verify the whole chain — curl, dependencies, URL,
key shape and an authenticated `GET /api/v1/users/self`.

## Usage

### Commands

| Command | What it does |
|---|---|
| `:Tuleap issues` | Telescope picker over the `issue` tracker |
| `:Tuleap epics` / `:Tuleap stories` | same, for the `epic` / `story` trackers |
| `:Tuleap list <key>` | any tracker key, id or shortname |
| `:Tuleap search [kind]` | prompt for a TQL query, then list the matches |
| `:Tuleap mine` | artifacts assigned to you |
| `:Tuleap view [id]` | artifact detail view (id under the cursor by default) |
| `:Tuleap create [kind]` | create an artifact from a form |
| `:Tuleap edit [id]` | edit fields in a form |
| `:Tuleap comment [id]` | post a follow-up comment |
| `:Tuleap close [id]` | move to a closed status |
| `:Tuleap delete [id]` | delete after an explicit confirmation |
| `:Tuleap attach [id]` | attach to an epic or plan in a sprint (asks which) |
| `:Tuleap epic [id]` | attach under an epic |
| `:Tuleap plan [id]` | plan in a sprint |
| `:Tuleap sprints` | sprint / milestone picker |
| `:Tuleap sprint [id]` | sprint dashboard (summary + both charts) |
| `:Tuleap burndown [id]` / `:Tuleap burnup [id]` | a single chart, full height |
| `:Tuleap projects` / `:Tuleap trackers` | pick the active project / browse a tracker |
| `:Tuleap browse [id]` / `:Tuleap yank [id]` | open in the browser / yank the URL |
| `:Tuleap status` / `:Tuleap refresh` / `:Tuleap health` | connection info, clear cache, checkhealth |
| `:Tuleap doctor` | probe the instance and report what the plugin found |

Where an `[id]` is optional, the plugin uses the artifact reference under the
cursor (`bug #1234`, `#1234`), then the last artifact you opened, then a prompt.

### Picker mappings

| Key | Action |
|---|---|
| `<CR>` | open the detail view |
| `<C-e>` | edit in a form |
| `<C-x>` | close the artifact |
| `<C-a>` | add a comment |
| `<C-o>` | open in the browser |
| `<C-y>` | yank the URL |
| `<M-a>` | attach to an epic or a sprint |
| `<M-d>` | delete the artifact |

In the sprint picker: `<CR>` dashboard, `<C-b>` burndown, `<C-u>` burnup,
`<C-l>` drill into sub-milestones, `<C-a>` sprint content, `<C-o>` browser.

### View mappings

Detail view: `q` close · `r` refresh · `e` edit · `c` comment · `x` close ·
`A` attach · `D` delete · `o` browser · `y` yank URL · `L` follow link ·
`g?` help.

Sprint dashboard: `q` close · `r` refresh · `t` cycle burndown/burnup/both ·
`c` sprint content · `o` browser.

Forms: `<C-s>` or `ZZ` submit · `ZQ` abort · `<CR>` pick a value on a list
field. A form is a markdown buffer where each field is a `### Label` section —
delete a whole section to leave that field untouched.

## Hierarchy

`:Tuleap attach` does two different things depending on what you pick:

- **Epic** — adds an artifact-link of nature `_is_child` *on the epic*, pointing
  at the issue. That is the direction Tuleap's hierarchy uses, and the one
  `linked_artifacts?direction=forward` reports. The nature is configurable via
  `links.parent_nature`.
- **Sprint** — adds the artifact to the milestone content with
  `PATCH /milestones/{id}/content {add: [...]}`, falling back to a `PUT` of the
  full id list on instances that do not implement `PATCH` there.

Tuleap writes an artifact-link field as a *whole list*, so attaching reads the
current links back first and **refuses to write at all if it cannot read
them** — an unreadable field can never silently wipe an artifact's children.
Attaching something already attached is a no-op.

## Configuration

Defaults, all optional:

```lua
require("tuleap").setup({
  url = nil,                  -- defaults to $TULEAP_URL
  token = nil,                -- defaults to $TULEAP_TOKEN
  env = { url = "TULEAP_URL", token = "TULEAP_TOKEN" },
  token_cmd = nil,            -- e.g. { "pass", "show", "tuleap/token" }

  project = nil,              -- numeric id or shortname; nil opens the picker

  -- Maps this plugin's vocabulary onto your trackers. A value is a tracker
  -- id, a name, or a list of candidate names tried in order.
  trackers = {
    issue = { "issue", "bug" }, epic = "epic",
    story = { "story", "user story" },
    task = "task", sprint = "sprint", release = "release",
  },

  request = {
    timeout = 20000,          -- ms
    insecure = false,         -- self-signed certificates
    proxy = nil,
    per_page = 100,
    max_pages = 20,
    extra_headers = {},
  },

  cache = { enabled = true, ttl = 300 },

  links = { parent_nature = "_is_child" },  -- nature used by `:Tuleap attach`

  ui = {
    border = "rounded",
    width = 0.85, height = 0.85,
    winblend = 0,
    show_help_hint = true,
    form_fields = "common",   -- "common" | "required" | "all"
    icons = { epic = "󰓾", bug = "", sprint = "󰁪", open = "", closed = "", ... },
  },

  chart = {
    style = "braille",        -- "braille" | "blocks" | "ascii"
    height = 18,
    width = nil,              -- defaults to the window width
    show_ideal = true,
    show_today = true,
    colors = { "TuleapChartSeries1", "TuleapChartSeries2",
               "TuleapChartSeries3", "TuleapChartSeries4" },
  },

  picker = { opts = {}, preview = true, show_id = true },

  keymaps = { detail = {...}, form = {...}, chart = {...} },  -- see :h tuleap-config

  log_level = "info",
})
```

### Tracker mapping

Tuleap has no built-in notion of "issue" or "epic": everything is an *artifact*
in a *tracker*, and every instance names them differently. `trackers` maps the
plugin's vocabulary onto yours, by shortname (`item_name`) or numeric id:

```lua
trackers = {
  issue = { "issue", "bug" },  -- first match wins; or a plain id like 42
  epic = "epic",
  story = "user story",
  sprint = "sprint",
}
```

Names are matched against both the tracker shortname (`item_name`) and its
label, **ignoring case, punctuation and plurals** — so `story` finds a tracker
labelled "User Stories". A list of candidates is tried in order, which is how
the default `issue` key lands on *Issues* where that tracker exists and on
*Bugs* where it does not. When nothing matches, the error names every tracker
in the project so the fix is a copy-paste.

Extra keys are allowed and become usable as `:Tuleap list <key>`.
`:Tuleap doctor` lists any tracker that no key reaches.

## Highlights

Every group links to a standard one and can be overridden:

`TuleapTitle` `TuleapHeader` `TuleapLabel` `TuleapValue` `TuleapXref`
`TuleapOpen` `TuleapClosed` `TuleapUser` `TuleapDate` `TuleapHint`
`TuleapCommentAuthor` `TuleapCommentBody` `TuleapProgressFilled`
`TuleapChartTitle` `TuleapChartAxis` `TuleapChartLabel` `TuleapChartMarker`
`TuleapChartSeries1…4`

## Notes and limitations

- **Burnup**: Tuleap only exposes `GET /milestones/{id}/burnup` on recent
  versions. When the route is missing, tuleap.nvim derives the burnup from the
  burndown (`completed = capacity − remaining`, flat scope line) and labels the
  chart *derived from burndown*. The derived scope line cannot show scope
  changes that happened during the sprint.
- **Delete**: Tuleap restricts artifact deletion to site administrators and
  enforces a per-project daily quota, so `:Tuleap delete` commonly answers
  `403` or `429`. This is the server's policy, not a plugin limitation.
- **Close**: an artifact is closed by setting its status semantic to a value
  outside the tracker's open values. A tracker without a status semantic cannot
  be closed from here. Some instances do not publish the open/closed split at
  all; there the plugin says so and lists every status rather than guessing —
  otherwise "New" would be offered as a way to close an artifact.
- **TQL**: `expert_query` uses the *field names* of your instance, which differ
  between projects. `:Tuleap mine` tries `assigned_to = MYSELF()` first and
  falls back to a client-side filter when the server rejects it.
- **Sprints** need the Agile Dashboard plugin enabled on the project.
- **"My artifacts"** tries a server-side TQL query built from each tracker's own
  contributor semantic (the field is rarely literally called `assigned_to`),
  then falls back to filtering the tracker's artifacts locally — including when
  the query is *accepted but matches nothing*, which is the usual reason the
  list looks empty. The fallback reads the whole tracker, so it is slower.
- **The burndown ideal line** is anchored on the milestone's start and end
  dates, not on the burndown payload's `duration`: Tuleap counts that duration
  in working days on many configurations, which would stop the guideline short
  of the deadline. The line starts at the first recorded scope rather than at
  the team capacity.
- **Pagination**: Tuleap caps the `limit` parameter per route (50 on
  `/projects`, higher elsewhere) and answers `400` rather than clamping it.
  tuleap.nvim learns each route's cap — from the `X-PAGINATION-LIMIT-MAX`
  header and from the error message itself — then replays the page and reuses
  the cap for the rest of the session, so `request.per_page` is an upper bound
  rather than an exact value.

## Development

```bash
make test       # plenary busted specs (68 of them)
make preview    # render every view against canned payloads, no instance needed
make lint       # luacheck + stylua, when installed
```

`tests/preview.lua` stubs the transport with the fixtures in
`tests/fixtures/`, so views and charts can be iterated on without a Tuleap
server:

```bash
nvim --headless -u NONE -l tests/preview.lua detail
nvim --headless -u NONE -l tests/preview.lua sprint
```

## License

MIT
