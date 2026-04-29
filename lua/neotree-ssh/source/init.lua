local fs = require("neotree-ssh.fs")
local ssh = require("neotree-ssh.ssh")
local log = require("neotree-ssh.log")

local M = {
  name = "neotree-ssh",
  display_name = "󰒍 SSH",
}

M._connections = {}

local function ok(mod)
  local okay, m = pcall(require, mod)
  if okay then return m end
  return nil
end

local function need_neotree()
  return assert(ok("neo-tree.sources.common.file-items"), "neo-tree not installed"),
         assert(ok("neo-tree.ui.renderer"), "neo-tree not installed"),
         assert(ok("neo-tree.utils"), "neo-tree not installed")
end

function M.make_url(host_name, remote_path)
  if not remote_path:match("^/") then
    remote_path = "/" .. remote_path
  end
  return "ssh:/" .. host_name .. remote_path
end

function M.parse_url(url)
  if type(url) ~= "string" then return nil, nil end
  local rest = url:match("^ssh:/(.+)$")
  if not rest then return nil, nil end
  local host = rest:match("^([^/]+)")
  if not host then return nil, nil end
  local remote = rest:sub(#host + 1)
  if remote == "" then remote = "/" end
  return host, remote
end

local function join_remote(parent_remote, name)
  if parent_remote == "/" then return "/" .. name end
  return parent_remote .. "/" .. name
end
M._join_remote = join_remote

function M._reset_connections()
  M._connections = {}
end

function M._get_conn(host_name)
  if M._connections[host_name] then
    return M._connections[host_name]
  end
  local main = require("neotree-ssh")
  local cfg = main.get_config()
  local host_cfg = cfg.hosts[host_name]
  if not host_cfg then
    return nil, string.format("unknown host %q (configure under hosts in setup)", host_name)
  end
  local conn = ssh.new({
    host = host_cfg.host,
    user = host_cfg.user,
    port = host_cfg.port,
    identity_file = host_cfg.identity_file,
    control_path = cfg.control_path,
    control_persist = cfg.control_persist,
    connect_timeout = cfg.connect_timeout,
    _executor = host_cfg._executor,
  })
  M._connections[host_name] = conn
  return conn, nil
end

function M._set_connection(host_name, conn)
  M._connections[host_name] = conn
end

local function pick_type(entry)
  local t = entry.is_link and entry.resolved_type or entry.type
  if t == "other" or t == "link" then t = "file" end
  return t
end

---Builds a directory item with its immediate children populated.
---Returns root item, child count, error.
---@param host_name string
---@param remote_path string
function M._build_dir(host_name, remote_path)
  local file_items = need_neotree()
  local conn, err = M._get_conn(host_name)
  if not conn then return nil, 0, err end

  local entries, list_err = fs.list_dir(conn, remote_path)
  if list_err then return nil, 0, list_err end

  local root_url = M.make_url(host_name, remote_path)
  local context = file_items.create_context()
  context.state = { path = root_url, default_expanded_nodes = {} }

  local root = file_items.create_item(context, root_url, "directory")
  root.name = host_name .. ":" .. remote_path
  root.loaded = true
  context.folders[root.path] = root

  for _, entry in ipairs(entries) do
    local child_remote = join_remote(remote_path, entry.name)
    local child_url = M.make_url(host_name, child_remote)
    local item_type = pick_type(entry)
    local child = file_items.create_item(context, child_url, item_type)
    child.extra = child.extra or {}
    child.extra.remote_path = child_remote
    child.extra.host_name = host_name
    child.extra.size = entry.size
    child.extra.mtime = entry.mtime
    if item_type == "directory" then
      child.loaded = false
    end
  end

  table.sort(root.children or {}, function(a, b)
    if a.type ~= b.type then
      return a.type == "directory"
    end
    return a.name < b.name
  end)
  return root, #(root.children or {}), nil
end

function M.navigate(state, path, path_to_reveal, callback, async)
  local _, renderer = need_neotree()
  state.dirty = false
  if path == nil then
    path = state.path
  end
  if path == nil then
    log.error("navigate called without a path; use :NeotreeSshOpen <host>")
    return
  end

  local host_name, remote_path = M.parse_url(path)
  if not host_name then
    log.error("invalid ssh path %q (expected ssh:/host/path)", tostring(path))
    return
  end

  state.path = path

  local root, _, err = M._build_dir(host_name, remote_path)
  if err then
    log.error("failed to load %s: %s", path, err)
    return
  end

  state.default_expanded_nodes = { root.id }
  renderer.show_nodes({ root }, state)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

function M.toggle_directory(state, node, path_to_reveal, skip_redraw, recursive, callback)
  local _, renderer = need_neotree()
  local tree = state.tree
  if not node then node = assert(tree:get_node()) end
  if node.type ~= "directory" then return end

  state.explicitly_opened_nodes = state.explicitly_opened_nodes or {}

  if node.loaded == false then
    local node_url = node:get_id()
    local host_name, remote_path = M.parse_url(node_url)
    if not host_name then
      log.error("cannot expand non-ssh node %q", tostring(node_url))
      return
    end
    state.explicitly_opened_nodes[node_url] = true

    local root, _, err = M._build_dir(host_name, remote_path)
    if err then
      log.error("failed to expand %s: %s", node_url, err)
      return
    end
    node.loaded = true
    renderer.show_nodes(root.children or {}, state, node_url, callback)
    if not skip_redraw then
      renderer.redraw(state)
    end
  elseif node:has_children() then
    if node:is_expanded() then
      node:collapse()
      state.explicitly_opened_nodes[node:get_id()] = false
    else
      node:expand()
      state.explicitly_opened_nodes[node:get_id()] = true
    end
    if not skip_redraw then
      renderer.redraw(state)
    end
  end
end

function M.refresh(state)
  M.navigate(state, state.path)
end

function M.setup(_, _) end

return M
