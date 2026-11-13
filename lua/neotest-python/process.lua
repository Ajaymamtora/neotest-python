local nio = require("nio")

-- neotest.lib.process.run does not forward cwd to libuv. Use a per-process
-- cwd, never a temporary :cd, so discovery and environment probes can overlap.
return function(command, root)
  local future = nio.control.future()
  vim.system(command, { cwd = root, text = true }, future.set)
  local result = future.wait()
  nio.scheduler()
  return result.code, result
end
