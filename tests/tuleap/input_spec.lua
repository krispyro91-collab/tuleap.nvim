local form = require("tuleap.ui.form")

--- Open an input window, run `act` on it, and report what was submitted.
---@param act fun(buf: integer, win: table)
---@return string? submitted
local function with_input(act)
  local submitted
  local win = form.input({
    title = "Comment",
    intro = { "an intro comment line" },
    on_submit = function(text, close)
      submitted = text
      close()
    end,
  })
  act(win.buf, win)
  if win:valid() then
    vim.bo[win.buf].modified = false
    win:close()
  end
  return submitted
end

describe("form.input", function()
  it("submits on :w like the field form does", function()
    -- Regression: the buffer was left as a scratch `nofile`, so `:w` failed
    -- with E382 and the comment looked impossible to send.
    local submitted = with_input(function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a typed comment" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end)
    assert.equals("a typed comment", submitted)
  end)

  it("is writable", function()
    with_input(function(buf)
      assert.equals("acwrite", vim.bo[buf].buftype)
      assert.is_true(vim.bo[buf].modifiable)
    end)
  end)

  it("strips the intro comment lines from what it sends", function()
    local submitted = with_input(function(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      lines[#lines + 1] = "the body"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end)
    assert.equals("the body", submitted)
  end)

  it("keeps a modified buffer open when q is pressed", function()
    local win
    local submitted = with_input(function(buf, w)
      win = w
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "half written" })
      vim.bo[buf].modified = true
      local notify = vim.notify
      vim.notify = function() end
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("normal q")
      end)
      vim.wait(50, function()
        return false
      end)
      vim.notify = notify
      assert.is_true(w:valid(), "q must not discard a typed comment")
    end)
    assert.is_nil(submitted)
    assert.is_false(win:valid())
  end)

  it("leaves insert mode once the comment is sent", function()
    -- Regression: the prompt starts in insert mode and <C-s> submits from
    -- there, so closing it dropped the user back into the artifact view still
    -- in insert mode, where `e` and every other mapping were dead.
    local under = vim.api.nvim_get_current_win()
    local win = form.input({
      title = "Comment",
      on_submit = function(_, close)
        close()
      end,
    })
    vim.api.nvim_feedkeys(vim.keycode("ia comment<C-s>"), "x", false)
    assert.is_false(win:valid())
    assert.equals(under, vim.api.nvim_get_current_win())
    assert.equals("n", vim.api.nvim_get_mode().mode)
  end)
end)
