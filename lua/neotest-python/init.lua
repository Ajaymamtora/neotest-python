local base = require("neotest-python.base")
local create_adapter = require("neotest-python.adapter")

---@class neotest-python.AdapterConfig
---@field dap? table
---@field pytest_discover_instances? boolean
---@field is_test_file? fun(file_path: string):boolean
---@field python? string|string[]|fun(root: string):string|string[]|nil
---@field args? string[]|fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field runner? string|fun(python_command: string[]): string

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

---@param config neotest-python.AdapterConfig
local augment_config = function(config)
  local get_python_command = base.get_python_command
  if config.python then
    get_python_command = function(root)
      local python = config.python

      if is_callable(config.python) then
        python = config.python(root)
      end

      if python == nil then
        python = base.get_python_command(root)
      elseif type(python) == "string" then
        python = { python }
      end
      assert(type(python) == "table" and #python > 0, "Python interpreter argv must not be empty")
      python = vim.deepcopy(python)
      for _, arg in ipairs(python) do
        assert(type(arg) == "string" and arg ~= "", "Python interpreter argv contains an invalid argument")
      end
      -- Preserve argv flags, but resolve relative interpreter paths before
      -- runner detection or DAP can execute them from another working directory.
      if not vim.startswith(python[1], "/") and not python[1]:match("^%a:[/\\]")
        and python[1]:find("[/\\]") then
        python[1] = vim.fs.joinpath(root, python[1])
      end
      return python
    end
  end

  local get_args = function()
    return {}
  end

  if is_callable(config.args) then
    get_args = config.args
  elseif config.args then
    get_args = function()
      return config.args
    end
  end

  local get_runner = base.get_runner
  if is_callable(config.runner) then
    get_runner = config.runner
  elseif config.runner then
    get_runner = function()
      return config.runner
    end
  end

  ---@type neotest-python._AdapterConfig
  return {
    pytest_discovery = config.pytest_discover_instances,
    dap_args = config.dap,
    get_runner = get_runner,
    get_args = get_args,
    is_test_file = config.is_test_file or base.is_test_file,
    get_python_command = get_python_command,
  }
end

local PythonNeotestAdapter = create_adapter(augment_config({}))

setmetatable(PythonNeotestAdapter, {
  __call = function(_, config)
    return create_adapter(augment_config(config))
  end,
})

return PythonNeotestAdapter
