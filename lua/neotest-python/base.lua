local nio = require("nio")
local lib = require("neotest.lib")
local run_process = require("neotest-python.process")

local M = {}

function M.is_test_file(file_path)
  if not vim.endswith(file_path, ".py") then
    return false
  end
  local elems = vim.split(file_path, lib.files.sep)
  local file_name = elems[#elems]
  return vim.startswith(file_name, "test_") or vim.endswith(file_name, "_test.py")
end

M.module_exists = function(module, python_command)
  return run_process(vim
    .iter({
      python_command,
      "-c",
      "import " .. module,
    })
    :flatten()
    :totable()) == 0
end

local python_command_mem = {}
local venv_bin = vim.loop.os_uname().sysname:match("Windows") and "Scripts" or "bin"

---@return string[]
function M.get_python_command(root)
  root = root or vim.loop.cwd()
  local cache_key = root .. "\0" .. (vim.env.VIRTUAL_ENV or "")
  if python_command_mem[cache_key] then
    return python_command_mem[cache_key]
  end
  local function remember(command)
    python_command_mem[cache_key] = command
    return command
  end

  -- A selected project's environment takes precedence over another project's
  -- activated environment. Do not resolve project files against Neovim's cwd.
  for _, pattern in ipairs({ "*", ".*" }) do
    local matches = nio.fn.glob(vim.fs.joinpath(root, pattern, "pyvenv.cfg"), false, true)
    for _, match in ipairs(matches) do
      local python = vim.fs.joinpath(vim.fs.dirname(match), venv_bin, "python")
      if nio.fn.executable(python) == 1 then
        return remember({ python })
      end
    end
  end

  if vim.env.VIRTUAL_ENV then
    return remember({ vim.fs.joinpath(vim.env.VIRTUAL_ENV, venv_bin, "python") })
  end

  local function project_command(marker, command, transform)
    if not lib.files.exists(vim.fs.joinpath(root, marker)) then
      return nil
    end
    local success, exit_code, data = pcall(run_process, command, root)
    if success and exit_code == 0 and data and data.stdout then
      local path = vim.trim(data.stdout)
      if path ~= "" then
        return remember({ transform and transform(path) or path })
      end
    end
  end

  local command = project_command("Pipfile", { "pipenv", "--py" })
    or project_command("pyproject.toml", { "poetry", "env", "info", "-p" }, function(path)
      return vim.fs.joinpath(path, venv_bin, "python")
    end)
    or project_command("uv.lock", { "uv", "run", "python", "-c", "import sys; print(sys.executable)" })
  if command then
    return command
  end

  -- Fallback to system Python (exepath returns an empty string when absent).
  local python = nio.fn.exepath("python3")
  if python == "" then
    python = nio.fn.exepath("python")
  end
  return remember({ python ~= "" and python or "python" })
end

---@return string
function M.get_script_path()
  local paths = vim.api.nvim_get_runtime_file("neotest.py", true)
  for _, path in ipairs(paths) do
    if vim.endswith(path, ("neotest-python%sneotest.py"):format(lib.files.sep)) then
      return path
    end
  end

  error("neotest.py not found")
end

---@param python_command string[]
---@param config neotest-python._AdapterConfig
---@param runner string
---@return string
local function scan_test_function_pattern(runner, config, python_command, root)
  local test_function_pattern = "^test"
  if runner == "pytest" and config.pytest_discovery then
    local cmd = vim.iter({ python_command, M.get_script_path(), "--pytest-extract-test-name-template" }):flatten()
        :totable()
    local _, data = run_process(cmd, root)

    for line in vim.gsplit(data.stdout, "\n", true) do
      if string.sub(line, 1, 1) == "{" and string.find(line, "python_functions") ~= nil then
        local pytest_option = vim.json.decode(line)
        test_function_pattern = pytest_option.python_functions
      end
    end
  end
  return test_function_pattern
end

---@param python_command string[]
---@param config neotest-python._AdapterConfig
---@param runner string
---@return string
M.treesitter_queries = function(runner, config, python_command, root)
  local test_function_pattern = scan_test_function_pattern(runner, config, python_command, root)
  return string.format([[
    ;; Match undecorated functions
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "%s"))
      @test.definition

    ;; Match decorated function, including decorators in definition
    (decorated_definition
      ((function_definition
        name: (identifier) @test.name)
        (#match? @test.name "%s")))
        @test.definition

    ;; Match decorated classes, including decorators in definition
    (decorated_definition
      (class_definition
       name: (identifier) @namespace.name))
      @namespace.definition

    ;; Match undecorated classes: namespaces nest so #not-has-parent is used
    ;; to ensure each namespace is annotated only once
    (
     (class_definition
      name: (identifier) @namespace.name)
      @namespace.definition
     (#not-has-parent? @namespace.definition decorated_definition)
    )
  ]], test_function_pattern, test_function_pattern)
end

local root_markers = { "pyproject.toml", "setup.cfg", "mypy.ini", "pytest.ini", "setup.py" }

function M.get_root(path)
  local boundary = vim.fs.root(path, { ".git" })
  local stat = vim.loop.fs_stat(path)
  local start = stat and stat.type == "directory" and path or vim.fs.dirname(path)
  local marker = vim.fs.find(root_markers, {
    path = start,
    upward = true,
    stop = boundary and vim.fs.dirname(boundary) or nil,
  })[1]
  return marker and vim.fs.dirname(marker) or nil
end

-- Run/discovery fallback only: don't register this adapter for every Git repo.
function M.get_project_root(path)
  local stat = vim.loop.fs_stat(path)
  return M.get_root(path)
    or vim.fs.root(path, { ".git" })
    or (stat and stat.type == "directory" and path or vim.fs.dirname(path))
end

function M.create_dap_config(python_path, script_path, script_args, dap_args, root)
  return vim.tbl_extend("keep", {
    type = "python",
    name = "Neotest Debugger",
    request = "launch",
    python = python_path,
    program = script_path,
    cwd = root,
    args = script_args,
  }, dap_args or {})
end

local stored_runners = {}

function M.get_runner(python_path)
  local command_str = table.concat(python_path, " ")
  if stored_runners[command_str] then
    return stored_runners[command_str]
  end
  local vim_test_runner = vim.g["test#python#runner"]
  if vim_test_runner == "pyunit" then
    return "unittest"
  end
  if
      vim_test_runner and lib.func_util.index({ "unittest", "pytest", "django" }, vim_test_runner)
  then
    return vim_test_runner
  end
  local runner = M.module_exists("pytest", python_path) and "pytest"
      or M.module_exists("django", python_path) and "django"
      or "unittest"
  stored_runners[command_str] = runner
  return runner
end

return M
