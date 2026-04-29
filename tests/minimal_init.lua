local lazy = vim.env.NEOTREE_SSH_DEPS or vim.fn.expand("~/.local/share/nvim/lazy")

local function add(name, required)
  local path = lazy .. "/" .. name
  if vim.fn.isdirectory(path) == 0 then
    if required then
      error(name .. " not found at " .. path)
    end
    return
  end
  vim.opt.rtp:prepend(path)
end

add("plenary.nvim", true)
add("nui.nvim", false)
add("nvim-web-devicons", false)
add("neo-tree.nvim", false)
add("telescope.nvim", false)

vim.opt.rtp:prepend(vim.fn.getcwd())

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
