std = "luajit"
globals = { "vim" }
read_globals = { "describe", "it", "before_each", "after_each", "assert", "arg" }
max_line_length = 120
exclude_files = { ".deps" }
ignore = {
  "212", -- unused argument (callbacks keep their signature)
  "631", -- line too long in doc comments
}
