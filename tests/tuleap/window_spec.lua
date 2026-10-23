local config = require("tuleap.config")
local window = require("tuleap.ui.window")

describe("floating windows", function()
  it("sits below the notification layer by default", function()
    local win = window.open({ title = "t" })
    local win_config = vim.api.nvim_win_get_config(win.win)
    -- nvim-notify leaves zindex unset, so its windows land on 50. A panel
    -- sharing that value wins the tie by being focused, and hides them.
    assert.equals(45, win_config.zindex)
    assert.is_true(win_config.zindex < 50)
    win:close()
  end)

  it("honours a configured zindex", function()
    local previous = config.options.ui.zindex
    config.options.ui.zindex = 30
    local win = window.open({})
    assert.equals(30, vim.api.nvim_win_get_config(win.win).zindex)
    win:close()
    config.options.ui.zindex = previous
  end)

  it("lets a single window override it", function()
    local win = window.open({ zindex = 70 })
    assert.equals(70, vim.api.nvim_win_get_config(win.win).zindex)
    win:close()
  end)

  it("still drops title and footer when there is no border", function()
    local previous = config.options.ui.border
    config.options.ui.border = "none"
    local win = window.open({ title = "t", footer = "f" })
    local win_config = vim.api.nvim_win_get_config(win.win)
    assert.is_nil(win_config.title)
    assert.is_nil(win_config.footer)
    win:close()
    config.options.ui.border = previous
  end)

  it("gives focus back to the view it was opened from", function()
    local detail = window.open({ title = "detail" })
    local form = window.open({ title = "form" })
    -- A picker opened from the form and closed again, as `<CR>` on a list
    -- field does: Neovim's previous window is now gone.
    local picker = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      width = 10,
      height = 2,
      row = 1,
      col = 1,
    })
    vim.api.nvim_win_close(picker, true)
    assert.equals(form.win, vim.api.nvim_get_current_win())

    form:close()
    assert.equals(detail.win, vim.api.nvim_get_current_win())
    detail:close()
  end)

  it("leaves focus alone when closed while unfocused", function()
    local first = window.open({ title = "first" })
    local second = window.open({ title = "second" })
    vim.api.nvim_set_current_win(second.win)
    first:close()
    assert.equals(second.win, vim.api.nvim_get_current_win())
    second:close()
  end)
end)
