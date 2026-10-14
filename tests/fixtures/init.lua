--- Canned Tuleap REST payloads, shaped like the real API, used by the preview
--- harness and the specs so neither needs a live instance.

local M = {}

local function iso(offset_days)
  return os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() + offset_days * 86400)
end

M.user = { id = 102, username = "alice", display_name = "Alice Martin (alice)" }

M.tracker = {
  id = 7,
  label = "Bugs",
  item_name = "bug",
  project = { id = 101, label = "Apollo" },
  semantics = {
    title = { field_id = 1 },
    description = { field_id = 2 },
    status = { field_id = 3, open_values = { 301, 302 } },
    contributor = { field_id = 4 },
  },
  fields = {
    { field_id = 1, name = "summary", label = "Summary", type = "string", required = true, permissions = { "read", "update", "create" } },
    { field_id = 2, name = "details", label = "Description", type = "text", required = false, permissions = { "read", "update", "create" } },
    {
      field_id = 3,
      name = "status",
      label = "Status",
      type = "sb",
      required = true,
      permissions = { "read", "update", "create" },
      values = {
        { id = 301, label = "New" },
        { id = 302, label = "In progress" },
        { id = 303, label = "Fixed" },
        { id = 304, label = "Won't fix" },
      },
    },
    {
      field_id = 4,
      name = "assigned_to",
      label = "Assigned to",
      type = "msb",
      permissions = { "read", "update", "create" },
      -- Shaped like a real user-bound field: `label` is the bare username and
      -- the full name only appears under `user_reference`.
      values = {
        {
          id = 102,
          label = "alice",
          user_reference = { id = "102", username = "alice", real_name = "Alice Martin (alice)" },
        },
        {
          id = 103,
          label = "bob",
          user_reference = { id = "103", username = "bob", real_name = "Bob Dupont (bob)" },
        },
      },
    },
    { field_id = 5, name = "remaining_effort", label = "Remaining effort", type = "float", permissions = { "read", "update" } },
    { field_id = 6, name = "priority", label = "Priority", type = "sb", permissions = { "read", "update" }, values = { { id = 401, label = "High" }, { id = 402, label = "Low" } } },
  },
}

M.artifact = {
  id = 1234,
  xref = "bug #1234",
  title = "SSO redirect loops on first login",
  status = "In progress",
  is_open = true,
  html_url = "/plugins/tracker/?aid=1234",
  tracker = { id = 7, label = "Bugs", item_name = "bug" },
  submitted_by_user = M.user,
  submitted_on = iso(-9),
  last_modified_date = iso(-1),
  values = {
    { field_id = 1, label = "Summary", type = "string", value = "SSO redirect loops on first login" },
    {
      field_id = 2,
      label = "Description",
      type = "text",
      value = { content = "<p>Logging in through the <b>SAML</b> provider bounces between the IdP and Tuleap.</p><p>Only happens on the very first login of a new account.</p>", format = "html" },
    },
    { field_id = 3, label = "Status", type = "sb", values = { { id = 302, label = "In progress" } } },
    { field_id = 4, label = "Assigned to", type = "msb", values = { { id = 102, display_name = "Alice Martin (alice)" } } },
    { field_id = 5, label = "Remaining effort", type = "float", value = 3 },
    { field_id = 6, label = "Priority", type = "sb", values = { { id = 401, label = "High" } } },
  },
}

--- The same artifact as Tuleap returns it on instances that send bound values
--- as bare `bind_value_ids` and keep text fields flat, with no labels and no
--- nested `{content, format}`. The views must render identically.
M.artifact_bind_ids = {
  id = 1234,
  xref = "bug #1234",
  title = "SSO redirect loops on first login",
  status = "In progress",
  tracker = { id = 7, label = "Bugs", item_name = "bug" },
  submitted_by_user = M.user,
  submitted_on = iso(-9),
  last_modified_date = iso(-1),
  values = {
    { field_id = 1, label = "Summary", type = "string", value = "SSO redirect loops on first login" },
    {
      field_id = 2,
      label = "Description",
      type = "text",
      value = "<p>Logging in through the <b>SAML</b> provider bounces.</p>",
      format = "html",
      commonmark = "Logging in through the **SAML** provider bounces.",
    },
    { field_id = 3, label = "Status", type = "sb", bind_value_ids = { 302 } },
    { field_id = 4, label = "Assigned to", type = "msb", bind_value_ids = { 102, 103 } },
    { field_id = 5, label = "Remaining effort", type = "float", value = 3 },
    { field_id = 6, label = "Priority", type = "sb", bind_value_ids = { 401 } },
  },
}

M.artifacts = { M.artifact }
for index = 1, 12 do
  local open = index % 3 ~= 0
  M.artifacts[#M.artifacts + 1] = {
    id = 1200 + index,
    xref = ("bug #%d"):format(1200 + index),
    title = ("Sample defect number %d that needs a slightly longer title"):format(index),
    status = open and "New" or "Fixed",
    is_open = open,
    tracker = { id = 7, label = "Bugs", item_name = "bug" },
    submitted_by_user = M.user,
    submitted_on = iso(-20 + index),
    last_modified_date = iso(-index),
    values = {},
  }
end

M.changesets = {
  {
    id = 1,
    submitted_by_details = M.user,
    submitted_on = iso(-3),
    last_comment = { body = "Reproduced on staging with a brand new account.", format = "text" },
  },
  {
    id = 2,
    submitted_by_details = { id = 103, display_name = "Bob Dupont (bob)" },
    submitted_on = iso(-1),
    last_comment = { body = "<p>Patch is on <code>fix/sso-loop</code>, waiting for review.</p>", format = "html" },
  },
}

M.links = {
  { id = 42, xref = "story #42", title = "Single sign-on support" },
  { id = 77, xref = "task #77", title = "Harden the session cookie" },
}

--- An epic tracker, with the artifact link field that holds the hierarchy.
M.epic_tracker = {
  id = 8,
  label = "Epics",
  item_name = "epic",
  semantics = { title = { field_id = 20 }, status = { field_id = 21, open_values = { 501 } } },
  fields = {
    { field_id = 20, name = "summary", label = "Summary", type = "string", required = true, permissions = { "read", "update" } },
    { field_id = 21, name = "status", label = "Status", type = "sb", permissions = { "read", "update" }, values = { { id = 501, label = "Open" }, { id = 502, label = "Done" } } },
    { field_id = 22, name = "links", label = "Links", type = "art_link", permissions = { "read", "update" } },
  },
}

--- An epic that already has two children: attaching a third must keep them.
M.epic = {
  id = 42,
  xref = "epic #42",
  title = "Single sign-on support",
  status = "Open",
  is_open = true,
  tracker = { id = 8, label = "Epics", item_name = "epic" },
  values = {
    { field_id = 20, label = "Summary", type = "string", value = "Single sign-on support" },
    { field_id = 21, label = "Status", type = "sb", bind_value_ids = { 501 } },
    {
      field_id = 22,
      label = "Links",
      type = "art_link",
      links = { { id = 777, type = "_is_child" }, { id = 888, type = "_is_child" } },
    },
  },
}

M.milestone = {
  id = 555,
  label = "Sprint 42",
  semantic_status = "Open",
  start_date = iso(-9),
  end_date = iso(5),
  duration = 14,
  capacity = 40,
  initial_effort = 38,
  remaining_effort = 11,
  html_url = "/plugins/agiledashboard/?action=show&aid=555",
}

M.milestones = {
  { id = 500, label = "Release 1.2", semantic_status = "Open", start_date = iso(-30), end_date = iso(30) },
  M.milestone,
  { id = 556, label = "Sprint 43", semantic_status = "Planned", start_date = iso(5), end_date = iso(19) },
}

--- `/milestones/{id}/burndown` payload.
M.burndown = (function()
  local points, remaining = {}, 38
  for day = 0, 9 do
    -- Record the day's scope first: point one is the sprint's day-zero scope,
    -- which is where a burndown guideline starts.
    points[#points + 1] = { date = iso(-9 + day), remaining_effort = remaining }
    remaining = math.max(0, remaining - (day == 4 and -3 or 3.4))
  end
  -- `duration` here counts working days only (10), while the milestone runs
  -- for 14 calendar days: that mismatch is what used to stop the ideal line
  -- short of the deadline.
  return { duration = 10, capacity = 38, start_date = iso(-9), is_under_calculation = false, points_with_date = points }
end)()

return M
