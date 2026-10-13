---@mod tuleap.util.log Logging helpers
---
--- Thin wrapper around |vim.notify| that respects `config.log_level` and
--- always tags messages with the plugin title so they group nicely in
--- notification UIs such as nvim-notify or snacks.nvim.

local M = {}

local LEVELS = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
  off = vim.log.levels.OFF,
}

--- Resolve the configured threshold lazily: the log module is required by
--- config itself, so it cannot hold a hard reference to it.
---@return integer
local function threshold()
  local ok, config = pcall(require, "tuleap.config")
  if not ok or not config.options then
    return vim.log.levels.INFO
  end
  return LEVELS[config.options.log_level] or vim.log.levels.INFO
end

---@param level integer
---@param msg string
---@param ... any formatting arguments
local function notify(level, msg, ...)
  if level < threshold() then
    return
  end
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, msg, ...)
    msg = ok and formatted or msg
  end
  vim.schedule(function()
    vim.notify(msg, level, { title = "Tuleap", icon = "󰌪" })
  end)
end

function M.trace(msg, ...) notify(vim.log.levels.TRACE, msg, ...) end
function M.debug(msg, ...) notify(vim.log.levels.DEBUG, msg, ...) end
function M.info(msg, ...) notify(vim.log.levels.INFO, msg, ...) end
function M.warn(msg, ...) notify(vim.log.levels.WARN, msg, ...) end
function M.error(msg, ...) notify(vim.log.levels.ERROR, msg, ...) end

--- Write a verbose entry to the debug log file (`:messages` stays clean).
--- Only does work when the configured level is `trace` or `debug`.
---@param msg string
function M.dev(msg, ...)
  if threshold() > vim.log.levels.DEBUG then
    return
  end
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, msg, ...)
    msg = ok and formatted or msg
  end
  local path = vim.fs.joinpath(vim.fn.stdpath("state") --[[@as string]], "tuleap.log")
  local fd = io.open(path, "a")
  if not fd then
    return
  end
  fd:write(("[%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), msg))
  fd:close()
end

--- Path of the debug log file, exposed for :checkhealth.
---@return string
function M.logfile()
  return vim.fs.joinpath(vim.fn.stdpath("state") --[[@as string]], "tuleap.log")
end

return M
