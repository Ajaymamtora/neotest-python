# neotest-python

[Neotest](https://github.com/rcarriga/neotest) adapter for python.
Supports Pytest and unittest test files.

Requires the treesitter parser for python.

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")
  }
})
```

You can optionally supply configuration settings:
```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
        -- Extra arguments for nvim-dap configuration
        -- See https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for values
        dap = { justMyCode = false },
        -- Command line arguments for runner
        -- Can also be a function to return dynamic values
        args = {"--log-level", "DEBUG"},
        -- Runner to use. Will use pytest if available by default.
        -- Can be a function to return dynamic value.
        runner = "pytest",
        -- Custom python path for the runner.
        -- Can be a string or a list of strings.
        -- Can also be a function to return dynamic value.
        -- Relative interpreter paths are resolved against the selected project.
        -- A callback receives that root and may return nil to use inference.
        -- If omitted, checks project virtualenvs, the activated environment,
        -- Pipenv/Poetry/uv, then system Python.
        python = { ".venv/bin/python", "-X", "dev" },
        -- Returns if a given file path is a test file.
        -- NB: This function is called a lot so don't perform any heavy tasks within it.
        is_test_file = function(file_path)
          ...
        end,
        -- !!EXPERIMENTAL!! Enable shelling out to `pytest` to discover test
        -- instances for files containing a parametrize mark (default: false)
        pytest_discover_instances = true,
    })
  }
})

```

## Project and result ownership

Discovery, run commands and debugpy launches use the selected file's nearest
Python project marker (`pyproject.toml`, `setup.cfg`, `mypy.ini`, `pytest.ini`,
`setup.py`), bounded by its Git checkout/worktree. Without a marker, execution
uses that checkout root, or the file's directory outside Git. Changing Neovim's
working directory does not change an already selected run's cwd or interpreter.
This execution fallback does not register Python for arbitrary non-Python Git
repositories.

The `python` option still accepts a string, argv list (including interpreter
flags), or `function(root)` returning either. A nil callback result uses normal
inference. Project-local virtualenvs take precedence over an unrelated activated
environment; Pipenv, Poetry and uv commands run in the selected root.
`RunSpec.cwd` and the generated DAP `cwd` always refer to this root.

Missing, corrupt, empty, invalid-status or unrelated result reports fail the
selected subtree with an infrastructure error and the runner output, even if
the runner exited successfully. Genuine reported pytest/unittest skips remain
skips. Parameterized function selections accept their `[case]` outcomes; class
and file selections require their own descendants, not similarly prefixed IDs.
Enable `pytest_discover_instances` when selecting individual parameter cases.
Per-run report and stream files are removed after results are consumed, including
aborted runs whose runner does not produce a report.

## Tests

Install pytest in the Python interpreter used for testing, and run:

```sh
PYTHON=/path/to/python scripts/test
```

Requires Neovim with its Python treesitter parser, and `neotest` and `nvim-nio`
in sibling directories. Set `NEOTEST_DEPENDENCIES` to their parent directory
when using another layout.
The native suite exercises real pytest/unittest selections and report parsing;
project-manager executable fixtures isolate cwd and stdout handling without
requiring Poetry, Pipenv or uv installations.
