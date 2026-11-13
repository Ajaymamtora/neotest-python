-- Run via scripts/test. Uses native Neovim, nio, and real pytest/unittest.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dependencies = vim.env.NEOTEST_DEPENDENCIES or vim.fn.fnamemodify(plugin, ":h")
for _, path in ipairs({ plugin, dependencies .. "/neotest", dependencies .. "/nvim-nio" }) do
  vim.opt.runtimepath:append(path)
end
local nio = require("nio")
local lib = require("neotest.lib")
local Tree = require("neotest.types").Tree
local base = require("neotest-python.base")
local python = vim.env.PYTHON or vim.fn.exepath("python3")
local run_process = require("neotest-python.process")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.loop.fs_realpath(tmp)
local original_cwd, original_venv = vim.fn.getcwd(), vim.env.VIRTUAL_ENV
local count = 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
  count = count + 1
end
local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end
local function tree(id, kind, path)
  return Tree.from_list(
    { { id = id, type = kind or "test", path = path or id:match("^[^:]+") } },
    function(pos)
      return pos.id
    end
  )
end
local done, failure = false, nil
nio.run(function()
  local ok, err = xpcall(function()
    local project = tmp .. "/worktree/project"
    local other = tmp .. "/other"
    local file = project .. "/test_example.py"
    write(tmp .. "/pyproject.toml", "[tool.pytest.ini_options]")
    write(tmp .. "/worktree/.git", "gitdir: /not-needed-for-root-discovery")
    write(project .. "/pyproject.toml", "[tool.pytest.ini_options]")
    write(other .. "/pyproject.toml", "[tool.pytest.ini_options]")
    write(
      file,
      [[import os
import pytest

@pytest.mark.parametrize("value", [1, 2], ids=["one", "two"])
def test_param(value):
    assert value > 0

class TestGroup:
    def test_pass(self):
        assert os.path.isfile("pyproject.toml")
    def test_fail(self):
        assert False, "intentional failure"
    @pytest.mark.skip(reason="intentional skip")
    def test_skip(self):
        pass
]]
    )
    vim.fn.chdir(other)
    eq(project, base.get_project_root(file))
    local markerless = tmp .. "/worktree/plain/test_plain.py"
    write(markerless, "def test_plain(): pass")
    eq(nil, base.get_root(markerless))
    eq(tmp .. "/worktree", base.get_project_root(markerless))
    vim.fn.delete(tmp .. "/pyproject.toml")
    local standalone = tmp .. "/standalone/test_plain.py"
    write(standalone, "def test_plain(): pass")
    eq(tmp .. "/standalone", base.get_project_root(standalone))

    local callback_root
    local adapter = require("neotest-python")({
      python = function(root)
        callback_root = root
        return { python, "-X", "dev" }
      end,
      runner = "pytest",
      pytest_discover_instances = true,
    })
    assert(vim.treesitter.language.add("python"), "Python treesitter parser is required")
    local discovered = adapter.discover_positions(file)
    assert(
      discovered:get_key(file .. "::test_param[one]"),
      "parameter discovery missed selected case"
    )
    assert(
      discovered:get_key(file .. "::test_param[two]"),
      "parameter discovery missed second case"
    )
    eq(project, callback_root)
    local selected = tree(file .. "::test_param[one]", "test", file)
    local spec = adapter.build_spec({ tree = selected, strategy = "dap" })
    eq(project, callback_root)
    eq(project, spec.cwd)
    eq(project, spec.strategy.cwd)
    eq({ python, "-X", "dev" }, spec.strategy.python)
    eq({ python, "-X", "dev" }, vim.list_slice(spec.command, 1, 3))
    local function execute(selection)
      local run = adapter.build_spec({ tree = selection })
      local code, output = run_process(run.command, run.cwd)
      local results = adapter.results(run, { code = code, output = "/runner-output" }, selection)
      eq(false, not not lib.files.exists(run.context.results_path))
      eq(false, not not lib.files.exists(run.context.stream_path))
      return results, code, output
    end
    local results, code = execute(selected)
    eq(0, code)
    eq({ file .. "::test_param[one]" }, vim.tbl_keys(results))
    eq("passed", results[selected:data().id].status)
    results, code = execute(tree(file .. "::TestGroup", "namespace", file))
    eq(1, code)
    eq("passed", results[file .. "::TestGroup::test_pass"].status)
    eq("failed", results[file .. "::TestGroup::test_fail"].status)
    eq("skipped", results[file .. "::TestGroup::test_skip"].status)
    results, code = execute(tree(file, "file"))
    eq(1, code)
    eq(5, vim.tbl_count(results))
    eq("passed", results[file .. "::test_param[two]"].status)
    -- The non-instance API still aggregates parameter outcomes under the function.
    local aggregate = require("neotest-python")({ python = python, runner = "pytest" })
    local aggregate_tree = tree(file .. "::test_param", "test", file)
    local aggregate_spec = aggregate.build_spec({ tree = aggregate_tree })
    local aggregate_code = run_process(aggregate_spec.command, aggregate_spec.cwd)
    eq(
      "passed",
      aggregate.results(aggregate_spec, { code = aggregate_code }, aggregate_tree)[aggregate_tree:data().id].status
    )

    -- Authoritative report fixtures exercise the real reader/decoder, not a mock adapter.
    local function report(payload, selection, expected)
      selection = selection or selected
      local run = adapter.build_spec({ tree = selection })
      if payload then
        lib.files.write(run.context.results_path, payload)
      end
      local outcomes = adapter.results(run, { code = 0, output = "/runner-output" }, selection)
      eq(expected or "failed", outcomes[selection:data().id].status)
      if not expected then
        eq("/runner-output", outcomes[selection:data().id].output)
        assert(outcomes[selection:data().id].errors[1].message:find("Python test runner", 1, true))
      end
      eq(false, not not lib.files.exists(run.context.stream_path))
    end
    adapter.results(spec, { code = 1 }, selected) -- also closes the unused DAP spec
    for _, payload in ipairs({
      "{",
      "null",
      "[]",
      "{}",
      "true",
      '{"foreign":{"status":"passed"}}',
      vim.json.encode({ [selected:data().id] = { status = "invented" } }),
      vim.json.encode({ [selected:data().id] = false }),
      vim.json.encode({ [selected:data().id .. "suffix"] = { status = "passed" } }),
      vim.json.encode({ [selected:data().id .. "[other]"] = { status = "passed" } }),
    }) do
      report(payload)
    end
    report(nil) -- missing report with a clean exit is not a skip
    report(vim.json.encode({ [selected:data().id] = { status = "skipped" } }), nil, "skipped")
    local function_tree = tree(file .. "::test_param", "test", file)
    local parameter_run = adapter.build_spec({ tree = function_tree })
    lib.files.write(
      parameter_run.context.results_path,
      vim.json.encode({ [selected:data().id] = { status = "passed" } })
    )
    eq(
      "passed",
      adapter.results(parameter_run, { code = 0 }, function_tree)[selected:data().id].status
    )
    report(
      vim.json.encode({ [file .. "::Other::test_x"] = { status = "passed" } }),
      tree(file .. "::TestGroup", "namespace", file)
    )
    report(
      vim.json.encode({ [file .. "-other::test_x"] = { status = "passed" } }),
      tree(file, "file")
    )

    -- A nil callback delegates to inference; argv strings and relative paths remain supported.
    vim.env.VIRTUAL_ENV = tmp .. "/unrelated-venv"
    local venv = project .. "/.venv"
    write(venv .. "/pyvenv.cfg", "home = /unused")
    vim.fn.mkdir(venv .. "/bin", "p")
    assert(vim.loop.fs_symlink(python, venv .. "/bin/python"))
    eq({ venv .. "/bin/python" }, base.get_python_command(project))
    for _, option in ipairs({
      ".venv/bin/python",
      { ".venv/bin/python", "-X", "dev" },
      function()
        return nil
      end,
    }) do
      local configured = require("neotest-python")({ python = option, runner = "pytest" })
      local run = configured.build_spec({ tree = selected })
      eq(venv .. "/bin/python", run.command[1])
      configured.results(run, { code = 1 }, selected)
    end
    vim.env.VIRTUAL_ENV = nil
    for _, manager in ipairs({
      { marker = "Pipfile", name = "pipenv", stdout = python, expected = python },
      {
        marker = "pyproject.toml",
        name = "poetry",
        stdout = venv,
        expected = venv .. "/bin/python",
      },
      { marker = "uv.lock", name = "uv", stdout = python, expected = python },
    }) do
      local root = tmp .. "/manager-" .. manager.name
      write(root .. "/" .. manager.marker, "")
      local command = tmp .. "/bin/" .. manager.name
      write(
        command,
        "#!/bin/sh\nprintf '%s' \"$PWD\" > '"
          .. root
          .. "/cwd'\nprintf '%s\\n' '"
          .. manager.stdout
          .. "'"
      )
      vim.fn.setfperm(command, "rwx------")
      local old_path = vim.env.PATH
      vim.env.PATH = tmp .. "/bin:" .. old_path
      eq({ manager.expected }, base.get_python_command(root))
      eq(vim.loop.fs_realpath(root), lib.files.read(root .. "/cwd"))
      nio.scheduler()
      vim.env.PATH = old_path
    end

    local unit_file = project .. "/test_unit.py"
    write(
      unit_file,
      [[import unittest
class TestUnit(unittest.TestCase):
    def test_pass(self): self.assertEqual(1, 1)
    def test_fail(self): self.fail("intentional failure")
    @unittest.skip("intentional skip")
    def test_skip(self): pass
]]
    )
    local unit =
      require("neotest-python")({ python = { python, "-X", "dev" }, runner = "unittest" })
    for _, id in ipairs({
      unit_file,
      unit_file .. "::TestUnit",
      unit_file .. "::TestUnit::test_pass",
    }) do
      local selection = tree(
        id,
        id == unit_file and "file" or id:match("test_pass$") and "test" or "namespace",
        unit_file
      )
      local run = unit.build_spec({ tree = selection })
      local exit = run_process(run.command, run.cwd)
      local outcomes = unit.results(run, { code = exit }, selection)
      eq("passed", outcomes[unit_file .. "::TestUnit::test_pass"].status)
      if id ~= unit_file .. "::TestUnit::test_pass" then
        eq("failed", outcomes[unit_file .. "::TestUnit::test_fail"].status)
        eq("skipped", outcomes[unit_file .. "::TestUnit::test_skip"].status)
      end
    end
  end, debug.traceback)
  if not ok then
    failure = err
  end
  done = true
end)
assert(
  vim.wait(120000, function()
    return done
  end, 10),
  "adapter tests timed out"
)
vim.fn.chdir(original_cwd)
vim.env.VIRTUAL_ENV = original_venv
vim.fn.delete(tmp, "rf")
if failure then
  io.stderr:write(failure .. "\n")
  vim.cmd("cquit 1")
end
print("neotest-python: " .. count .. " assertions passed (native Neovim, real pytest/unittest)")
vim.cmd("qa!")
