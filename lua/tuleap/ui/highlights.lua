---@mod tuleap.ui.highlights Highlight groups
---
--- Every group is defined with `default = true` and links to a standard group,
--- so colorschemes and user config win without any extra plumbing. They are
--- re-applied on `ColorScheme` because many themes clear unknown links.

local M = {}

---@type table<string, vim.api.keyset.highlight>
M.groups = {
  TuleapTitle = { link = "Title" },
  TuleapHeader = { link = "Function" },
  TuleapLabel = { link = "Comment" },
  TuleapValue = { link = "Normal" },
  TuleapXref = { link = "Identifier" },
  TuleapOpen = { link = "DiagnosticOk" },
  TuleapClosed = { link = "DiagnosticHint" },
  TuleapUser = { link = "Constant" },
  TuleapDate = { link = "Special" },
  TuleapHint = { link = "NonText" },
  TuleapSeparator = { link = "WinSeparator" },
  TuleapCommentAuthor = { link = "Identifier" },
  TuleapCommentBody = { link = "Normal" },
  TuleapFieldRequired = { link = "DiagnosticWarn" },
  TuleapFieldName = { link = "@field" },
  TuleapProgressFilled = { link = "DiagnosticOk" },
  TuleapProgressEmpty = { link = "NonText" },
  TuleapWarn = { link = "DiagnosticWarn" },
  TuleapError = { link = "DiagnosticError" },

  TuleapChartTitle = { link = "Title" },
  TuleapChartAxis = { link = "NonText" },
  TuleapChartLabel = { link = "Comment" },
  TuleapChartMarker = { link = "DiagnosticWarn" },
  TuleapChartSeries1 = { link = "DiagnosticError" },
  TuleapChartSeries2 = { link = "DiagnosticOk" },
  TuleapChartSeries3 = { link = "DiagnosticInfo" },
  TuleapChartSeries4 = { link = "DiagnosticWarn" },
}

function M.setup()
  for name, opts in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", opts, { default = true }))
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("TuleapHighlights", { clear = true }),
    desc = "Re-apply tuleap.nvim highlight links",
    callback = function()
      for name, opts in pairs(M.groups) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", opts, { default = true }))
      end
    end,
  })
end

return M
