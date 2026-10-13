---@mod tuleap.actions User facing operations
---
--- Everything the commands, keymaps, pickers and views trigger lives here, so
--- the same logic backs `:Tuleap close 123`, `<leader>tux` and the `x` mapping
--- inside the detail view.

local artifacts = require("tuleap.api.artifacts")
local cache = require("tuleap.cache")
local config = require("tuleap.config")
local log = require("tuleap.util.log")
local trackers = require("tuleap.api.trackers")

local M = {}

--------------------------------------------------------------------------- utils

---@param url string
function M.open_url(url)
  if vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ vim.fn.has("mac") == 1 and "open" or "xdg-open", url }, { detach = true })
  end
end

---@param artifact table|integer
function M.open_in_browser(artifact)
  M.open_url(artifacts.url(artifact))
end

---@param artifact table|integer
function M.yank_url(artifact)
  local url = artifacts.url(artifact)
  vim.fn.setreg(vim.v.register or '"', url)
  vim.fn.setreg("+", url)
  log.info("Yanked %s", url)
end

--- Artifact reference under the cursor: `bug #123`, `story #12` or `#123`.
---@return integer?
function M.artifact_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for start, id in line:gmatch("()#(%d+)") do
    local stop = start + #id
    if col >= start - 12 and col <= stop + 1 then
      return tonumber(id)
    end
  end
  local word = vim.fn.expand("<cword>")
  return tonumber(word:match("^%d+$") and word or nil)
end

--- Resolve an artifact id from an explicit argument, the cursor or a prompt.
---@param id integer|string|nil
---@param cb fun(id: integer)
function M.resolve_artifact(id, cb)
  local numeric = tonumber(id)
  if numeric then
    return cb(numeric)
  end
  numeric = M.artifact_under_cursor()
  if numeric then
    return cb(numeric)
  end
  vim.ui.input({
    prompt = "Artifact id: ",
    default = config.state.last_artifact_id and tostring(config.state.last_artifact_id) or "",
  }, function(input)
    local parsed = tonumber(input and input:match("%d+"))
    if parsed then
      cb(parsed)
    end
  end)
end

--- Fields a form should offer for a tracker.
---@param tracker table
---@param mode "required"|"common"|"all"
---@return table[]
local function select_fields(tracker, mode)
  local editable = trackers.editable_fields(tracker)
  if mode == "all" then
    return editable
  end
  if mode == "required" then
    return vim.tbl_filter(function(field)
      return field.required
    end, editable)
  end

  -- "common": required fields plus the semantics people actually fill in.
  local wanted = {}
  for _, name in ipairs({ "title", "description", "status", "contributor" }) do
    local field = trackers.semantic_field(tracker, name)
    if field then
      wanted[field.field_id] = true
    end
  end
  local effort = trackers.effort_field(tracker)
  if effort then
    wanted[effort.field_id] = true
  end
  return vim.tbl_filter(function(field)
    return field.required or wanted[field.field_id]
  end, editable)
end

--------------------------------------------------------------------------- read

--- Open the detail view.
---@param id integer|string|nil
function M.view(id)
  M.resolve_artifact(id, function(resolved)
    require("tuleap.ui.detail").open(resolved)
  end)
end

--------------------------------------------------------------------------- write

---@class tuleap.ActionOpts
---@field on_done fun()?

--- Create an artifact in the tracker mapped to `kind`.
---@param kind string key of `config.trackers`, a tracker id or a shortname
---@param opts tuleap.ActionOpts?
function M.create(kind, opts)
  opts = opts or {}
  trackers.resolve(kind, function(err, tracker_id)
    if err then
      return log.error(err)
    end
    trackers.get(tracker_id, function(terr, tracker)
      if terr then
        return log.error(terr)
      end
      local fields = select_fields(tracker, config.options.ui.form_fields)
      if #fields == 0 then
        return log.error("No writable field found on tracker %s", tracker.label or tracker_id)
      end
      require("tuleap.ui.form").open({
        title = ("New %s"):format(tracker.label or tostring(kind)),
        fields = fields,
        intro = {
          ("Creating in tracker %s (#%d)"):format(tracker.label or "?", tracker_id),
          "Sections are `### Label`. Required fields are marked with *.",
        },
        on_submit = function(values, _, close)
          artifacts.create(tracker_id, values, function(cerr, created)
            if cerr then
              return log.error("Could not create artifact: %s", cerr)
            end
            close()
            log.info("Created artifact #%s", tostring(created and created.id))
            if created and created.id then
              require("tuleap.ui.detail").open(created.id, { refresh = true })
            end
            if opts.on_done then
              opts.on_done()
            end
          end)
        end,
      })
    end)
  end)
end

--- Edit an artifact's fields in a form.
---@param id integer|string|nil
---@param opts tuleap.ActionOpts?
function M.edit(id, opts)
  opts = opts or {}
  M.resolve_artifact(id, function(resolved)
    artifacts.get(resolved, function(err, artifact)
      if err then
        return log.error(err)
      end
      local tracker_id = artifact.tracker and artifact.tracker.id
      if not tracker_id then
        return log.error("Artifact #%d has no tracker", resolved)
      end
      trackers.get(tracker_id, function(terr, tracker)
        if terr then
          return log.error(terr)
        end
        local values_by_id = {}
        for _, value in ipairs(artifact.values or {}) do
          values_by_id[value.field_id] = value
        end
        require("tuleap.ui.form").open({
          title = ("Edit %s"):format(artifacts.xref(artifact)),
          fields = select_fields(tracker, config.options.ui.form_fields),
          values = values_by_id,
          comment = true,
          intro = {
            ("Editing %s — %s"):format(artifacts.xref(artifact), artifacts.title(artifact)),
            "Delete a whole `### Label` section to leave that field untouched.",
          },
          on_submit = function(values, comment, close)
            artifacts.update(resolved, values, comment, function(uerr)
              if uerr then
                return log.error("Could not update artifact: %s", uerr)
              end
              close()
              log.info("Updated %s", artifacts.xref(artifact))
              if opts.on_done then
                opts.on_done()
              end
            end)
          end,
        })
      end)
    end)
  end)
end

--- Post a follow-up comment.
---@param id integer|string|nil
---@param opts tuleap.ActionOpts?
function M.comment(id, opts)
  opts = opts or {}
  M.resolve_artifact(id, function(resolved)
    require("tuleap.ui.form").input({
      title = ("Comment on #%d"):format(resolved),
      intro = { "Markdown is sent as plain text to Tuleap." },
      on_submit = function(text, close)
        if text == "" then
          return log.warn("Empty comment, nothing sent")
        end
        artifacts.comment(resolved, text, function(err)
          if err then
            return log.error("Could not comment: %s", err)
          end
          close()
          log.info("Comment added to #%d", resolved)
          if opts.on_done then
            opts.on_done()
          end
        end)
      end,
    })
  end)
end

--- Move an artifact to a closed status, asking which one when there is a choice.
---@param id integer|string|nil
---@param opts tuleap.ActionOpts?
function M.close(id, opts)
  opts = opts or {}
  M.resolve_artifact(id, function(resolved)
    artifacts.get(resolved, function(err, artifact)
      if err then
        return log.error(err)
      end
      local tracker_id = artifact.tracker and artifact.tracker.id
      trackers.get(tracker_id, function(terr, tracker)
        if terr then
          return log.error(terr)
        end
        local closed = trackers.closed_values(tracker)
        if #closed == 0 then
          return log.error("Tracker %s exposes no closed status", tracker.label or "?")
        end

        local function finish(status_id)
          artifacts.close(resolved, { status_id = status_id }, function(cerr, chosen)
            if cerr then
              return log.error("Could not close #%d: %s", resolved, cerr)
            end
            log.info("%s → %s", artifacts.xref(artifact), chosen and chosen.label or "closed")
            if opts.on_done then
              opts.on_done()
            end
          end)
        end

        if #closed == 1 then
          return finish(closed[1].id)
        end
        vim.ui.select(closed, {
          prompt = ("Close %s as:"):format(artifacts.xref(artifact)),
          format_item = function(value)
            return value.label
          end,
        }, function(choice)
          if choice then
            finish(choice.id)
          end
        end)
      end)
    end)
  end)
end

--- Delete an artifact after an explicit confirmation.
---
--- Tuleap only allows site administrators to delete artifacts and enforces a
--- per-project daily quota, so this frequently answers 403 or 429.
---@param id integer|string|nil
---@param opts tuleap.ActionOpts?
function M.delete(id, opts)
  opts = opts or {}
  M.resolve_artifact(id, function(resolved)
    artifacts.get(resolved, function(err, artifact)
      local label = err and ("#" .. resolved) or
        ("%s — %s"):format(artifacts.xref(artifact), artifacts.title(artifact))
      vim.ui.input({
        prompt = ("Permanently delete %s? type the id to confirm: "):format(label),
      }, function(input)
        if tonumber(input) ~= resolved then
          return log.info("Deletion cancelled")
        end
        artifacts.delete(resolved, function(derr)
          if derr then
            return log.error("Could not delete #%d: %s", resolved, derr)
          end
          log.info("Deleted artifact #%d", resolved)
          if opts.on_done then
            opts.on_done()
          end
        end)
      end)
    end)
  end)
end

--------------------------------------------------------------------------- misc

--- Drop every cached response and re-read the token.
function M.refresh()
  cache.invalidate()
  config.forget_token()
  log.info("Tuleap cache cleared")
end

--- Short connection summary, used by `:Tuleap status`.
function M.status()
  local ok, err = config.validate()
  local lines = {
    ("URL        %s"):format(config.url() or "unset"),
    ("Token      %s"):format(config.token() and "set" or "missing"),
    ("Project    %s"):format(
      config.state.project_label
        or (config.state.project_id and ("#" .. config.state.project_id))
        or tostring(config.options.project or "not selected")
    ),
    ("Cache      %d entries"):format(cache.size()),
  }
  if not ok then
    lines[#lines + 1] = ""
    lines[#lines + 1] = err
  end
  log[ok and "info" or "warn"](table.concat(lines, "\n"))
end

return M
