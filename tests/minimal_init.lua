-- Minimal init for `make test`: adds this plugin and its dependencies to the
-- runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

--- Append the first candidate directory that exists.
---
--- Candidates are passed as varargs rather than a list: an unset environment
--- variable in the middle of a table literal makes `ipairs` stop at that hole,
--- which silently left the runtimepath empty.
---@param ... string|nil
---@return boolean found
local function add_dependency(...)
  for index = 1, select("#", ...) do
    local candidate = select(index, ...)
    if candidate and candidate ~= "" and vim.uv.fs_stat(candidate) then
      vim.opt.rtp:append(candidate)
      return true
    end
  end
  return false
end

local data = vim.fn.stdpath("data")

if
  not add_dependency(
    vim.env.PLENARY_DIR,
    data .. "/lazy/plenary.nvim",
    data .. "/site/pack/vendor/start/plenary.nvim",
    root .. "/.deps/plenary.nvim"
  )
then
  error("plenary.nvim not found — run `make deps` or set $PLENARY_DIR")
end

-- Telescope is optional: picker specs skip themselves when it is absent.
add_dependency(
  vim.env.TELESCOPE_DIR,
  data .. "/lazy/telescope.nvim",
  data .. "/site/pack/vendor/start/telescope.nvim",
  root .. "/.deps/telescope.nvim"
)

vim.o.swapfile = false
require("plenary.busted")
require("tuleap").setup({ url = "https://tuleap.example.test", token = "tlp-k1-test" })
