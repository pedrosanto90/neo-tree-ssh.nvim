local config = require("neotree-ssh.config")
local log = require("neotree-ssh.log")

local M = {}

M._state = {
  setup_done = false,
  config = nil,
}

function M.setup(user_cfg)
  local resolved = config.resolve(user_cfg)
  log.set_level(resolved.log_level)
  M._state.config = resolved
  M._state.setup_done = true

  if resolved.cache_dir and vim.fn.isdirectory(resolved.cache_dir) == 0 then
    pcall(vim.fn.mkdir, resolved.cache_dir, "p", tonumber("700", 8))
  end

  require("neotree-ssh.buffer").setup()

  log.debug("setup complete with %d host(s)", vim.tbl_count(resolved.hosts))
  return resolved
end

function M.get_config()
  if not M._state.setup_done then
    return config.resolve({})
  end
  return M._state.config
end

function M.is_setup()
  return M._state.setup_done
end

function M.list_hosts()
  return vim.tbl_keys(M.get_config().hosts)
end

function M.open(host_name, sub_path)
  local source = require("neotree-ssh.source")
  local cfg = M.get_config()
  local host_cfg = cfg.hosts[host_name]
  if not host_cfg then
    log.error("unknown host %q. Configured: %s", tostring(host_name), table.concat(M.list_hosts(), ", "))
    return false
  end
  local remote = sub_path and sub_path ~= "" and sub_path or host_cfg.remote_root
  local url = source.make_url(host_name, remote)
  local cmd_ok, cmd = pcall(require, "neo-tree.command")
  if not cmd_ok then
    log.error("neo-tree.nvim is not installed or not yet loaded")
    return false
  end
  cmd.execute({ source = source.name, dir = url, action = "show", reveal = false })
  return true
end

return M
