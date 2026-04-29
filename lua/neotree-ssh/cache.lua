local fs = require("neotree-ssh.fs")
local source = require("neotree-ssh.source")
local log = require("neotree-ssh.log")

local M = {}

local function shellquote(s)
  return "'" .. (s:gsub("'", [['\'']])) .. "'"
end

---Build a find command that lists all files under `root`, pruning the
---directories named in `exclude`. Output uses NUL separators.
function M.build_find_cmd(root, exclude)
  local parts = { "find", shellquote(root) }
  if exclude and #exclude > 0 then
    table.insert(parts, "(")
    table.insert(parts, "-type")
    table.insert(parts, "d")
    table.insert(parts, "(")
    for i, name in ipairs(exclude) do
      if i > 1 then table.insert(parts, "-o") end
      table.insert(parts, "-name")
      table.insert(parts, shellquote(name))
    end
    table.insert(parts, ")")
    table.insert(parts, "-prune")
    table.insert(parts, ")")
    table.insert(parts, "-o")
  end
  table.insert(parts, "-type")
  table.insert(parts, "f")
  table.insert(parts, "-print0")
  return table.concat(parts, " ")
end

local function parse_paths(stdout)
  local paths = {}
  for path in stdout:gmatch("([^%z]+)") do
    if path ~= "" then table.insert(paths, path) end
  end
  return paths
end
M._parse_paths = parse_paths

local function get_main()
  return require("neotree-ssh")
end

local function host_cache_path(host_name)
  local cfg = get_main().get_config()
  return cfg.cache_dir .. "/" .. host_name .. ".list"
end
M._host_cache_path = host_cache_path

local function ensure_cache_dir()
  local cfg = get_main().get_config()
  if vim.fn.isdirectory(cfg.cache_dir) == 0 then
    vim.fn.mkdir(cfg.cache_dir, "p", tonumber("700", 8))
  end
end

local function file_mtime(path)
  local stat = vim.uv.fs_stat(path)
  if stat then return stat.mtime.sec end
  return nil
end
M._file_mtime = file_mtime

function M.is_stale(host_name)
  local cfg = get_main().get_config()
  local mtime = file_mtime(host_cache_path(host_name))
  if not mtime then return true end
  return (os.time() - mtime) >= cfg.cache_ttl
end

function M.invalidate(host_name)
  local path = host_cache_path(host_name)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
    return true
  end
  return false
end

function M.write(host_name, paths)
  ensure_cache_dir()
  local cache_file = host_cache_path(host_name)
  local f, err = io.open(cache_file, "w")
  if not f then
    return false, err
  end
  f:write(table.concat(paths, "\n"))
  if #paths > 0 then f:write("\n") end
  f:close()
  return true
end

function M.read(host_name)
  local cache_file = host_cache_path(host_name)
  if vim.fn.filereadable(cache_file) ~= 1 then
    return nil, "no cache for " .. host_name
  end
  local paths = {}
  for line in io.lines(cache_file) do
    if line ~= "" then table.insert(paths, line) end
  end
  return paths, nil
end

function M.refresh(host_name, opts)
  opts = opts or {}
  local cfg = get_main().get_config()
  local host_cfg = cfg.hosts[host_name]
  if not host_cfg then
    return nil, string.format("unknown host %q", host_name)
  end
  local conn, err = source._get_conn(host_name)
  if not conn then return nil, err end

  local cmd = M.build_find_cmd(host_cfg.remote_root, host_cfg.exclude)
  log.debug("refreshing cache for %s: %s", host_name, cmd)
  local r = conn:exec(cmd, { timeout = opts.timeout })
  if r.code ~= 0 then
    return nil, r.stderr ~= "" and r.stderr or string.format("find exited %s", tostring(r.code))
  end

  local paths = parse_paths(r.stdout)
  local ok, write_err = M.write(host_name, paths)
  if not ok then return nil, write_err end
  return paths, nil
end

function M.get(host_name, opts)
  opts = opts or {}
  if not opts.force and not M.is_stale(host_name) then
    local cached = M.read(host_name)
    if cached then return cached, nil end
  end
  return M.refresh(host_name, opts)
end

return M
