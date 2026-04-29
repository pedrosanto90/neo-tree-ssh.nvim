local cc = require("neo-tree.sources.common.commands")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local source = require("neotree-ssh.source")

local M = {}

local source_name = source.name
local refresh = utils.wrap(manager.refresh, source_name)
local redraw = utils.wrap(manager.redraw, source_name)
local toggle_dir = utils.wrap(source.toggle_directory, nil)

M.refresh = refresh

M.toggle_node = function(state)
  cc.toggle_node(state, utils.wrap(source.toggle_directory, state))
end

M.toggle_directory = function(state)
  cc.toggle_directory(state, utils.wrap(source.toggle_directory, state))
end

M.open = function(state)
  cc.open(state, utils.wrap(source.toggle_directory, state))
end

M.open_split = function(state)
  cc.open_split(state, utils.wrap(source.toggle_directory, state))
end

M.open_vsplit = function(state)
  cc.open_vsplit(state, utils.wrap(source.toggle_directory, state))
end

M.open_tabnew = function(state)
  cc.open_tabnew(state, utils.wrap(source.toggle_directory, state))
end

M.open_drop = function(state)
  cc.open_drop(state, utils.wrap(source.toggle_directory, state))
end

M.close_node = cc.close_node
M.close_all_nodes = cc.close_all_nodes
M.close_all_subnodes = cc.close_all_subnodes

M.copy_to_clipboard = function(state)
  cc.copy_to_clipboard(state, redraw)
end

M.cut_to_clipboard = function(state)
  cc.cut_to_clipboard(state, redraw)
end

M.clear_clipboard = function(state)
  cc.clear_clipboard(state)
  redraw()
end

M.show_debug_info = cc.show_debug_info

M.navigate_up = function(state)
  local host_name, remote_path = source.parse_url(state.path or "")
  if not host_name or remote_path == "/" then return end
  local parent = remote_path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then parent = "/" end
  source.navigate(state, source.make_url(host_name, parent))
end

M.set_root = function(state)
  local node = state.tree:get_node()
  while node and node.type ~= "directory" do
    local parent_id = node:get_parent_id()
    node = parent_id and state.tree:get_node(parent_id) or nil
  end
  if node then
    source.navigate(state, node:get_id())
  end
end

cc._add_common_commands(M)

return M
