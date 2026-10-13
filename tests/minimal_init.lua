-- Minimal init for `make test`: adds this plugin and plenary to the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

for _, candidate in ipairs({
  vim.env.PLENARY_DIR,
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  root .. "/.deps/plenary.nvim",
}) do
  if candidate and vim.uv.fs_stat(candidate) then
    vim.opt.rtp:append(candidate)
    break
  end
end

vim.o.swapfile = false
require("plenary.busted")
require("tuleap").setup({ url = "https://tuleap.example.test", token = "tlp-k1-test" })
