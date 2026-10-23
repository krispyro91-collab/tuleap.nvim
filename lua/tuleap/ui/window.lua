---@mod tuleap.ui.window Floating window helper
---
--- A thin wrapper around `nvim_open_win` that gives every Tuleap view the same
--- look: centered float, configured border, scratch buffer, `q` to close and a
--- dedicated namespace for highlights.

local config = require("tuleap.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("tuleap")

---@class tuleap.Window
---@field buf integer
---@field win integer
local Window = {}
Window.__index = Window

---@param fraction number fraction of the editor, or an absolute size when > 1
---@param total integer
---@return integer
local function dimension(fraction, total)
  if fraction > 1 then
    return math.min(math.floor(fraction), total)
  end
  return math.max(10, math.floor(total * fraction))
end

---@class tuleap.WindowOpts
---@field title string?
---@field footer string?
---@field width number?
---@field height number?
---@field filetype string?
---@field modifiable boolean?
---@field enter boolean?
---@field zindex integer? overrides `ui.zindex` for this window

--- Open a floating window on a fresh scratch buffer.
---@param opts tuleap.WindowOpts?
---@return tuleap.Window
function M.open(opts)
  opts = opts or {}
  local ui = config.options.ui

  local width = dimension(opts.width or ui.width, vim.o.columns)
  local height = dimension(opts.height or ui.height, vim.o.lines - 4)

  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "tuleap"
  vim.bo[buf].modifiable = opts.modifiable == true

  -- `title` and `footer` require a border; drop them rather than error out.
  local decorated = ui.border ~= nil and ui.border ~= "none"

  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = ui.border,
    -- Keep notifications visible on top of the panel; see `ui.zindex`.
    zindex = opts.zindex or ui.zindex,
    title = (decorated and opts.title) and (" " .. opts.title .. " ") or nil,
    title_pos = (decorated and opts.title) and "center" or nil,
    footer = (decorated and opts.footer) and (" " .. opts.footer .. " ") or nil,
    footer_pos = (decorated and opts.footer) and "center" or nil,
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.wo[win].winblend = ui.winblend
  vim.wo[win].conceallevel = 2
  vim.wo[win].foldenable = false

  local self =
    setmetatable(
      { buf = buf, win = win, origin = origin, width = width, height = height, decorated = decorated },
      Window
    )

  self:map("q", function()
    self:close()
  end, "Close")
  self:map("<Esc>", function()
    self:close()
  end, "Close")

  return self
end

--- Replace the window contents.
---@param lines string[]
function Window:set_lines(lines)
  if not self:valid() then
    return
  end
  local modifiable = vim.bo[self.buf].modifiable
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = modifiable
  vim.bo[self.buf].modified = false
end

---@return string[]
function Window:get_lines()
  if not self:valid() then
    return {}
  end
  return vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

--- Apply a list of `{row, col, end_col, hl}` ranges (0-based, byte columns).
---@param highlights {row: integer, col: integer, end_col: integer, hl: string}[]
---@param clear boolean?
function Window:highlight(highlights, clear)
  if not self:valid() then
    return
  end
  if clear ~= false then
    vim.api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  end
  local line_count = vim.api.nvim_buf_line_count(self.buf)
  for _, item in ipairs(highlights) do
    if item.row < line_count then
      local line = vim.api.nvim_buf_get_lines(self.buf, item.row, item.row + 1, false)[1] or ""
      local end_col = item.end_col
      if end_col == -1 or end_col > #line then
        end_col = #line
      end
      if item.col <= end_col then
        pcall(vim.api.nvim_buf_set_extmark, self.buf, M.ns, item.row, item.col, {
          end_col = end_col,
          hl_group = item.hl,
        })
      end
    end
  end
end

--- Buffer-local normal-mode mapping. `lhs` may be false to skip.
---@param lhs string|false|nil
---@param rhs function
---@param desc string?
---@param mode string|string[]|nil
function Window:map(lhs, rhs, desc, mode)
  if not lhs or lhs == "" then
    return
  end
  vim.keymap.set(mode or "n", lhs, rhs, {
    buffer = self.buf,
    nowait = true,
    silent = true,
    desc = desc and ("Tuleap: " .. desc) or nil,
  })
end

---@return boolean
function Window:valid()
  return self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and self.win
    and vim.api.nvim_win_is_valid(self.win)
end

--- Close the window and, when it had focus, give focus back to the window it
--- was opened from. Neovim would otherwise go to its previous window, which a
--- picker opened from this one (`vim.ui.select`, Telescope) has replaced —
--- leaving the view underneath on screen but unfocused, deaf to its mappings.
function Window:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local focused = vim.api.nvim_get_current_win() == self.win
    vim.api.nvim_win_close(self.win, true)
    if focused and self.origin and self.origin ~= self.win and vim.api.nvim_win_is_valid(self.origin) then
      pcall(vim.api.nvim_set_current_win, self.origin)
    end
  end
  self.win = nil
end

---@param title string
function Window:set_title(title)
  if self:valid() and self.decorated then
    local win_config = vim.api.nvim_win_get_config(self.win)
    win_config.title = " " .. title .. " "
    win_config.title_pos = "center"
    pcall(vim.api.nvim_win_set_config, self.win, win_config)
  end
end

--- Show a transient "Loading …" placeholder.
---@param message string?
function Window:loading(message)
  self:set_lines({ "", "  " .. (message or "Loading …") })
  self:highlight({ { row = 1, col = 0, end_col = -1, hl = "TuleapHint" } })
end

--- Render an error message in place of the content.
---@param err string
function Window:error(err)
  local lines = { "", "   Tuleap request failed", "" }
  for _, line in ipairs(vim.split(err, "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. line
  end
  self:set_lines(lines)
  self:highlight({ { row = 1, col = 0, end_col = -1, hl = "TuleapError" } })
end

M.Window = Window

return M
