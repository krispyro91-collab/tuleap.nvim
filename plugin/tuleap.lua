-- User commands for tuleap.nvim. Kept free of `require("tuleap")` at load time
-- so the plugin itself stays lazy until a command actually runs.

if vim.g.loaded_tuleap then
  return
end
vim.g.loaded_tuleap = true

---@type table<string, fun(args: string[])>
local subcommands = {
  issues = function()
    require("tuleap").issues()
  end,
  epics = function()
    require("tuleap").epics()
  end,
  stories = function()
    require("tuleap").stories()
  end,
  sprints = function()
    require("tuleap").sprints()
  end,
  list = function(args)
    require("tuleap").list(args[1] or "issue")
  end,
  mine = function()
    require("tuleap").mine()
  end,
  search = function(args)
    require("tuleap").search(args[1])
  end,
  projects = function()
    require("tuleap").projects()
  end,
  trackers = function()
    require("tuleap").trackers()
  end,
  view = function(args)
    require("tuleap").view(args[1])
  end,
  create = function(args)
    require("tuleap").create(args[1])
  end,
  edit = function(args)
    require("tuleap").edit(args[1])
  end,
  comment = function(args)
    require("tuleap").comment(args[1])
  end,
  close = function(args)
    require("tuleap").close(args[1])
  end,
  delete = function(args)
    require("tuleap").delete(args[1])
  end,
  involve = function(args)
    require("tuleap").involve(args[1])
  end,
  uninvolve = function(args)
    require("tuleap").uninvolve(args[1])
  end,
  attach = function(args)
    require("tuleap").attach(args[1])
  end,
  epic = function(args)
    require("tuleap").attach_to_epic(args[1])
  end,
  plan = function(args)
    require("tuleap").attach_to_sprint(args[1])
  end,
  browse = function(args)
    require("tuleap").open_in_browser(args[1])
  end,
  yank = function(args)
    require("tuleap").yank_url(args[1])
  end,
  sprint = function(args)
    require("tuleap").sprint(args[1])
  end,
  burndown = function(args)
    require("tuleap").burndown(args[1])
  end,
  burnup = function(args)
    require("tuleap").burnup(args[1])
  end,
  refresh = function()
    require("tuleap").refresh()
  end,
  status = function()
    require("tuleap").status()
  end,
  doctor = function()
    require("tuleap").doctor()
  end,
  health = function()
    vim.cmd("checkhealth tuleap")
  end,
}

vim.api.nvim_create_user_command("Tuleap", function(opts)
  local args = opts.fargs
  local name = table.remove(args, 1) or "issues"
  local handler = subcommands[name]
  if not handler then
    return vim.notify(
      ("Tuleap: unknown subcommand %q\nTry one of: %s"):format(
        name,
        table.concat(vim.tbl_keys(subcommands), ", ")
      ),
      vim.log.levels.ERROR,
      { title = "Tuleap" }
    )
  end
  handler(args)
end, {
  nargs = "*",
  desc = "Tuleap: issues, sprints, charts …",
  complete = function(lead, line)
    -- Only complete the subcommand itself; arguments are free-form ids.
    if line:match("^%s*Tuleap%s+%S+%s") then
      return {}
    end
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, names)
  end,
})
