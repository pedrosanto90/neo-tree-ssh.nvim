if vim.g.loaded_neotree_ssh == 1 then
  return
end
vim.g.loaded_neotree_ssh = 1

vim.api.nvim_create_user_command("NeotreeSshRefresh", function(opts)
  local args = vim.split(opts.args, "%s+", { trimempty = true })
  local host = args[1]
  if not host then
    vim.notify("Usage: :NeotreeSshRefresh <host>", vim.log.levels.ERROR)
    return
  end
  local paths, err = require("neotree-ssh.cache").refresh(host)
  if err then
    vim.notify("neotree-ssh: refresh failed: " .. err, vim.log.levels.ERROR)
  else
    vim.notify(string.format("neotree-ssh: cached %d files for %s", #paths, host))
  end
end, {
  nargs = 1,
  complete = function() return require("neotree-ssh").list_hosts() end,
  desc = "Refresh the cached file list for an SSH host",
})

vim.api.nvim_create_user_command("NeotreeSshFiles", function(opts)
  local args = vim.split(opts.args, "%s+", { trimempty = true })
  local host = args[1]
  if not host then
    vim.notify("Usage: :NeotreeSshFiles <host>", vim.log.levels.ERROR)
    return
  end
  require("neotree-ssh.telescope").files(host)
end, {
  nargs = 1,
  complete = function() return require("neotree-ssh").list_hosts() end,
  desc = "Telescope file picker over a configured SSH host",
})

vim.api.nvim_create_user_command("NeotreeSshGrep", function(opts)
  local args = vim.split(opts.args, "%s+", { trimempty = true })
  local host = args[1]
  if not host then
    vim.notify("Usage: :NeotreeSshGrep <host>", vim.log.levels.ERROR)
    return
  end
  require("neotree-ssh.telescope").live_grep(host)
end, {
  nargs = 1,
  complete = function() return require("neotree-ssh").list_hosts() end,
  desc = "Telescope live_grep over a configured SSH host",
})

vim.api.nvim_create_user_command("NeotreeSshToggle", function()
  require("neotree-ssh").toggle()
end, {
  nargs = 0,
  desc = "Reopen the last SSH tree",
})

vim.api.nvim_create_user_command("NeotreeSshOpen", function(opts)
  local args = vim.split(opts.args, "%s+", { trimempty = true })
  local host = args[1]
  local sub = args[2]
  if not host then
    vim.notify("Usage: :NeotreeSshOpen <host> [sub_path]", vim.log.levels.ERROR)
    return
  end
  require("neotree-ssh").open(host, sub)
end, {
  nargs = "+",
  complete = function()
    return require("neotree-ssh").list_hosts()
  end,
  desc = "Open the SSH tree for a configured host",
})
