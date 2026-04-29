local M = {}

local function shellquote(s)
  return "'" .. (s:gsub("'", [['\'']])) .. "'"
end
M._shellquote = shellquote

local TYPE_MAP = {
  f = "file",
  d = "directory",
  l = "link",
  b = "block",
  c = "char",
  p = "pipe",
  s = "socket",
}

local function map_type(c)
  return TYPE_MAP[c] or "other"
end

local function parse_records(stdout)
  local entries = {}
  for record in stdout:gmatch("([^%z]+)") do
    local raw_type, resolved_type, size, mtime, name = record:match("^(.)\t(.)\t(%d+)\t([%d%.]+)\t(.*)$")
    if name and name ~= "" then
      table.insert(entries, {
        name = name,
        type = map_type(raw_type),
        resolved_type = map_type(resolved_type),
        size = tonumber(size) or 0,
        mtime = math.floor(tonumber(mtime) or 0),
        is_link = raw_type == "l",
      })
    end
  end
  return entries
end
M._parse_records = parse_records

local FIND_FORMAT = "%y\\t%Y\\t%s\\t%T@\\t%P\\0"

function M.list_dir(conn, path)
  local cmd = string.format(
    "find %s -mindepth 1 -maxdepth 1 -printf '%s'",
    shellquote(path),
    FIND_FORMAT
  )
  local r = conn:exec(cmd)
  if r.code ~= 0 then
    return nil, r.stderr ~= "" and r.stderr or string.format("list_dir failed (code %s)", tostring(r.code))
  end
  local entries = parse_records(r.stdout)
  table.sort(entries, function(a, b)
    if a.type == b.type then return a.name < b.name end
    return a.type == "directory"
  end)
  return entries, nil
end

function M.stat(conn, path)
  local cmd = string.format(
    "find %s -maxdepth 0 -printf '%%y\\t%%Y\\t%%s\\t%%T@\\t%%f\\0' 2>/dev/null",
    shellquote(path)
  )
  local r = conn:exec(cmd)
  if r.code ~= 0 or r.stdout == "" then
    return nil, "not found"
  end
  local entries = parse_records(r.stdout)
  return entries[1], nil
end

function M.exists(conn, path)
  local cmd = string.format("test -e %s && echo y || echo n", shellquote(path))
  local r = conn:exec(cmd)
  return r.code == 0 and r.stdout:match("^y") ~= nil
end

function M.read_file(conn, path)
  local cmd = string.format("cat %s", shellquote(path))
  local r = conn:exec(cmd)
  if r.code ~= 0 then
    return nil, r.stderr ~= "" and r.stderr or "read failed"
  end
  return r.stdout, nil
end

function M.write_file(conn, path, content)
  local cmd = string.format("cat > %s", shellquote(path))
  local r = conn:exec(cmd, { stdin = content })
  if r.code ~= 0 then
    return false, r.stderr ~= "" and r.stderr or "write failed"
  end
  return true, nil
end

function M.mkdir(conn, path, opts)
  opts = opts or {}
  local flag = opts.parents and "-p " or ""
  local cmd = string.format("mkdir %s%s", flag, shellquote(path))
  local r = conn:exec(cmd)
  if r.code ~= 0 then
    return false, r.stderr ~= "" and r.stderr or "mkdir failed"
  end
  return true, nil
end

function M.rm(conn, path, opts)
  opts = opts or {}
  local flag = opts.recursive and "-rf " or "-f "
  local cmd = string.format("rm %s%s", flag, shellquote(path))
  local r = conn:exec(cmd)
  if r.code ~= 0 then
    return false, r.stderr ~= "" and r.stderr or "rm failed"
  end
  return true, nil
end

function M.rename(conn, old_path, new_path)
  local cmd = string.format("mv %s %s", shellquote(old_path), shellquote(new_path))
  local r = conn:exec(cmd)
  if r.code ~= 0 then
    return false, r.stderr ~= "" and r.stderr or "rename failed"
  end
  return true, nil
end

return M
