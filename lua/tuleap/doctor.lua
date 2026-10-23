---@mod tuleap.doctor Instance introspection
---
--- `:Tuleap doctor` probes the live instance and reports what the plugin
--- actually found: which trackers resolved, what their semantics are named,
--- which optional REST routes exist, and the *shape* of one artifact's field
--- values.
---
--- It performs read-only requests, and reports field names, types and the keys
--- Tuleap used — never field contents — so the output is safe to share when
--- reporting a problem.

local artifacts = require("tuleap.api.artifacts")
local client = require("tuleap.api.client")
local config = require("tuleap.config")
local milestones = require("tuleap.api.milestones")
local projects = require("tuleap.api.projects")
local render = require("tuleap.ui.render")
local trackers = require("tuleap.api.trackers")
local users = require("tuleap.api.users")
local window = require("tuleap.ui.window")

local M = {}

local OK, WARN, FAIL = "✓", "!", "✗"

---@class tuleap.DoctorReport
---@field rows {icon: string, text: string, hl: string?}[]

--- Which keys Tuleap used to carry a field value. This is what decides whether
--- a value renders, so it is the first thing worth seeing when a view is blank.
---@param value table
---@return string
local function value_shape(value)
  local keys = {}
  for _, key in ipairs({
    "value",
    "values",
    "bind_value_ids",
    "bind_value_objects",
    "links",
    "reverse_links",
    "manual_value",
    "is_autocomputed",
    "format",
    "content",
    "file_descriptions",
  }) do
    if value[key] ~= nil then
      if key == "value" and type(value.value) == "table" then
        if vim.islist(value.value) then
          keys[#keys + 1] = ("value[%d]"):format(#value.value)
        else
          local nested = {}
          for nested_key in pairs(value.value) do
            nested[#nested + 1] = tostring(nested_key)
          end
          table.sort(nested)
          keys[#keys + 1] = ("value{%s}"):format(table.concat(nested, ","))
        end
      else
        keys[#keys + 1] = key
      end
    end
  end
  return #keys > 0 and table.concat(keys, " ") or "(empty)"
end

--- Run every probe, then hand the collected rows to `on_done`.
---@param on_update fun(rows: table[])
local function probe(on_update)
  local rows = {}
  local function add(icon, text, hl)
    rows[#rows + 1] = { icon = icon, text = text, hl = hl }
    on_update(rows)
  end
  local function section(text)
    rows[#rows + 1] = { section = text }
    on_update(rows)
  end

  section("Connection")
  add(OK, ("URL  %s"):format(config.url() or "unset"))

  users.self(function(err, me)
    if err then
      return add(FAIL, "GET /users/self — " .. err, "TuleapError")
    end
    add(OK, ("Authenticated as %s (id %s)"):format(users.label(me), tostring(me.id)))

    projects.current(function(perr, project_id)
      if perr or not project_id then
        add(WARN, "No project selected — run :Tuleap projects first", "TuleapWarn")
        return
      end
      add(OK, ("Project id %d"):format(project_id))

      trackers.list(project_id, function(terr, list)
        if terr then
          add(FAIL, "Could not list trackers — " .. terr, "TuleapError")
        else
          add(OK, ("%d trackers in this project"):format(#(list or {})))
          local names = {}
          for _, tracker in ipairs(list or {}) do
            names[#names + 1] = ("%s (#%d)"):format(tracker.item_name or tracker.label, tracker.id)
          end
          add(" ", "  " .. table.concat(names, ", "), "TuleapHint")
        end

        -- -------------------------------------------------- tracker mapping
        section("Tracker mapping")
        local keys = {}
        for key in pairs(config.options.trackers) do
          keys[#keys + 1] = key
        end
        table.sort(keys)

        local pending = #keys
        ---@type {id: integer, label: string}[]
        local resolved = {}
        local mapped = {}

        local function after_trackers()
          -- ------------------------------------------- unmapped trackers
          local unmapped = {}
          for _, tracker in ipairs(list or {}) do
            if not mapped[tracker.id] then
              unmapped[#unmapped + 1] = tracker
            end
          end
          if #unmapped > 0 then
            section("Trackers not reachable from any key")
            for _, tracker in ipairs(unmapped) do
              add(
                WARN,
                ("%s (%s, #%d) — add a `trackers` entry to browse it"):format(
                  tracker.label or "?",
                  tracker.item_name or "?",
                  tracker.id
                ),
                "TuleapWarn"
              )
            end
          end

          -- ------------------------------------------------ artifact shapes
          section("Artifact field value shapes")
          if #resolved == 0 then
            add(WARN, "No tracker resolved, cannot sample an artifact", "TuleapWarn")
          end

          local function milestone_probes()
            section("Agile dashboard")
            milestones.all(project_id, function(merr, list)
              if merr then
                add(FAIL, "Could not list milestones — " .. merr, "TuleapError")
                return
              end
              add(OK, ("%d milestones (releases + sprints)"):format(#(list or {})))
              local sample = nil
              for _, milestone in ipairs(list or {}) do
                if milestone.start_date then
                  sample = sample or milestone
                end
              end
              if not sample then
                add(WARN, "No milestone with a start date to probe charts with", "TuleapWarn")
                return
              end
              add(" ", ("Probing with %q (#%d)"):format(sample.label or "?", sample.id), "TuleapHint")

              client.get(("/milestones/%d/burndown"):format(sample.id), nil, function(berr, raw)
                if berr then
                  add(FAIL, "/burndown — " .. berr, "TuleapError")
                else
                  local count = type(raw.points_with_date) == "table" and #raw.points_with_date
                    or (type(raw.points) == "table" and #raw.points)
                    or 0
                  add(
                    OK,
                    ("/burndown — duration=%s capacity=%s points=%d"):format(
                      tostring(raw.duration),
                      tostring(raw.capacity),
                      count
                    )
                  )
                  local period_days = sample.end_date
                      and require("tuleap.util.date").days_between(
                        require("tuleap.util.date").parse(sample.start_date),
                        require("tuleap.util.date").parse(sample.end_date)
                      )
                    or nil
                  if period_days and raw.duration and period_days ~= tonumber(raw.duration) then
                    add(
                      WARN,
                      ("  duration (%s) differs from the milestone period (%d days) — the ideal line uses the period"):format(
                        tostring(raw.duration),
                        period_days
                      ),
                      "TuleapWarn"
                    )
                  end
                end

                client.get(("/milestones/%d/burnup"):format(sample.id), nil, function(uerr, burnup)
                  if uerr then
                    add(WARN, "/burnup not available — burnup is derived from the burndown", "TuleapWarn")
                  else
                    local count = type(burnup.points_with_date) == "table" and #burnup.points_with_date or 0
                    add(OK, ("/burnup — native, %d points"):format(count))
                  end
                end, { cache_ttl = 0 })
              end, { cache_ttl = 0 })
            end)
          end

          -- Walk the resolved trackers until one actually holds an artifact:
          -- the first mapped tracker is often empty, and then nothing is
          -- learnt about how this instance shapes its field values.
          local index = 0
          local function sample_next()
            index = index + 1
            local target = resolved[index]
            if not target then
              add(WARN, "No artifact found in any mapped tracker", "TuleapWarn")
              return milestone_probes()
            end
            artifacts.list(target.id, { limit = 1, max_pages = 1 }, function(aerr, found)
              local artifact = found and found[1]
              if aerr or not artifact then
                add(
                  " ",
                  ("  %s (#%d) is empty, trying the next tracker"):format(target.label, target.id),
                  "TuleapHint"
                )
                return sample_next()
              end
              add(" ", ("Sampling %s from %s"):format(artifacts.xref(artifact), target.label), "TuleapHint")
              trackers.get(artifact.tracker.id, function(_, tracker)
                local schema = {}
                for _, field in ipairs((tracker or {}).fields or {}) do
                  schema[field.field_id] = field
                end
                for _, value in ipairs(artifact.values or {}) do
                  local rendered = trackers.render_value(value, schema[value.field_id])
                  add(
                    rendered ~= "" and OK or WARN,
                    ("%-22s %-10s %s%s"):format(
                      (value.label or "?"):sub(1, 22),
                      value.type or "?",
                      value_shape(value),
                      rendered == "" and "   -> renders empty" or ""
                    ),
                    rendered == "" and "TuleapWarn" or nil
                  )
                end
                milestone_probes()
              end)
            end)
          end

          if #resolved == 0 then
            return milestone_probes()
          end
          sample_next()
        end

        if pending == 0 then
          return after_trackers()
        end

        for _, key in ipairs(keys) do
          trackers.resolve(key, function(rerr, tracker_id)
            if rerr then
              add(WARN, ("%-9s -> unresolved (%s)"):format(key, config.options.trackers[key]), "TuleapWarn")
              pending = pending - 1
              if pending == 0 then
                after_trackers()
              end
              return
            end
            trackers.get(tracker_id, function(gerr, tracker)
              if gerr then
                add(FAIL, ("%-9s -> #%d but unreadable"):format(key, tracker_id), "TuleapError")
              else
                resolved[#resolved + 1] = { id = tracker_id, label = tracker.label or key, key = key }
                mapped[tracker_id] = true
                local status_field, open_values, open_source = trackers.status(tracker)
                local contributor = trackers.semantic_field(tracker, "contributor")
                local effort = trackers.effort_field(tracker)
                -- `involved` and `category` have no semantic behind them:
                -- showing what `fields` matched is the only way to check it.
                local involved = trackers.involved_field(tracker)
                local category = trackers.category_field(tracker)
                add(OK, ("%-9s -> %s (#%d)"):format(key, tracker.label or "?", tracker_id))
                -- Two lines rather than one: six pairs no longer fit the
                -- panel, and a truncated report is a misleading one.
                add(
                  " ",
                  ("    title=%s  status=%s  assignee=%s"):format(
                    (trackers.semantic_field(tracker, "title") or {}).name or "—",
                    (status_field or {}).name or "—",
                    (contributor or {}).name or "—"
                  ),
                  "TuleapHint"
                )
                add(
                  " ",
                  ("    effort=%s  involved=%s  category=%s  links=%s"):format(
                    (effort or {}).name or "—",
                    (involved or {}).name or "—",
                    (category or {}).name or "—",
                    artifacts.link_field(tracker) and "yes" or "no"
                  ),
                  "TuleapHint"
                )
                if #open_values > 0 then
                  add(" ", ("    %d open statuses (from semantics.status.%s)"):format(#open_values, open_source), "TuleapHint")
                else
                  local keys_seen = {}
                  for semantic_key in pairs((tracker.semantics or {}).status or {}) do
                    keys_seen[#keys_seen + 1] = tostring(semantic_key)
                  end
                  table.sort(keys_seen)
                  add(
                    WARN,
                    ("    open statuses not published (semantics.status has: %s) — closing always asks"):format(
                      #keys_seen > 0 and table.concat(keys_seen, ", ") or "nothing"
                    ),
                    "TuleapWarn"
                  )
                end
                if not contributor then
                  add(WARN, "    no assignee semantic: :Tuleap mine cannot search this tracker", "TuleapWarn")
                else
                  -- Does this instance actually honour MYSELF()? Compare the
                  -- filtered count with the unfiltered one: equal means the
                  -- filter did nothing.
                  local query = ("%s = MYSELF()"):format(contributor.name or "assigned_to")
                  artifacts.list(tracker_id, { expert_query = query, limit = 25, max_pages = 1 }, function(qerr, filtered)
                    if qerr then
                      return add(" ", ("    TQL %q rejected — :Tuleap mine scans locally"):format(query), "TuleapHint")
                    end
                    artifacts.list(tracker_id, { limit = 25, max_pages = 1 }, function(_, all)
                      if #(filtered or {}) > 0 and #(filtered or {}) == #(all or {}) then
                        add(
                          WARN,
                          ("    %s returns every artifact (%d) — not filtering; results are verified locally"):format(
                            query,
                            #filtered
                          ),
                          "TuleapWarn"
                        )
                      else
                        add(" ", ("    %s -> %d of %d"):format(query, #(filtered or {}), #(all or {})), "TuleapHint")
                      end
                    end)
                  end)
                end
              end
              pending = pending - 1
              if pending == 0 then
                after_trackers()
              end
            end)
          end)
        end
      end)
    end)
  end)
end

--- Open the doctor report.
function M.open()
  local ok, err = config.validate()
  if not ok then
    return require("tuleap.util.log").error(err)
  end

  local win = window.open({ title = "Tuleap doctor", filetype = "tuleap-doctor" })
  win:loading("Probing the instance …")

  probe(function(rows)
    if not win:valid() then
      return
    end
    local builder = render.builder(win.width)
    builder:line({ { "  Tuleap doctor", "TuleapTitle" } })
    builder:rule("─", win.width)
    for _, row in ipairs(rows) do
      if row.section then
        builder:section(row.section)
      else
        builder:line({
          { "  " .. row.icon .. " ", row.hl or "TuleapOpen" },
          { row.text, row.hl or "TuleapValue" },
        })
      end
    end
    builder:blank()
    builder:line({ { "  Read-only. Field names and types only, never contents.", "TuleapHint" } })
    win:set_lines(builder.lines)
    win:highlight(builder.highlights)
  end)

  return win
end

return M
