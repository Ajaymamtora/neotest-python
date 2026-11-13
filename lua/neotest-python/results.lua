local nio = require("nio")
local lib = require("neotest.lib")

local statuses = { passed = true, failed = true, skipped = true }

local function contains(selected, id)
  if id == selected.id then
    return true
  end
  if id:sub(1, #selected.id) ~= selected.id then
    return false
  end
  local suffix = id:sub(#selected.id + 1)
  if selected.type == "test" then
    return selected.id:sub(-1) ~= "]" and suffix:sub(1, 1) == "[" and suffix:sub(-1) == "]"
  end
  if selected.type == "dir" then
    return suffix:sub(1, 1) == "/" or suffix:sub(1, 1) == "\\"
  end
  return suffix:sub(1, 2) == "::"
end

local function fail_selected(tree, result, message)
  local results = {}
  for _, position in tree:iter() do
    results[position.id] = {
      status = "failed",
      output = result.output,
      errors = { { message = "Python test runner: " .. message } },
    }
  end
  return results
end

return function(spec, result, tree)
  tree = tree or spec.context.tree
  spec.context.stop_stream()
  local ok, data = pcall(lib.files.read, spec.context.results_path)
  -- Reports and streams belong to this run, including failed/cancelled runs.
  nio.fn.delete(spec.context.results_path)
  nio.fn.delete(spec.context.stream_path)
  if not ok then
    return fail_selected(tree, result, "missing result report: " .. tostring(data))
  end
  local decoded, results = pcall(vim.json.decode, data, { luanil = { object = true } })
  if not decoded or type(results) ~= "table" or vim.tbl_isempty(results) then
    return fail_selected(tree, result, "invalid or empty result report")
  end
  local selected = tree:data()
  local found = false
  for id, entry in pairs(results) do
    if type(id) ~= "string" or type(entry) ~= "table" or not statuses[entry.status] then
      return fail_selected(tree, result, "invalid result entry")
    end
    found = found or contains(selected, id)
  end
  if not found then
    return fail_selected(tree, result, "report omitted selected position: " .. selected.id)
  end
  return results
end
