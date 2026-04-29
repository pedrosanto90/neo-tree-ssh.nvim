local common = require("neo-tree.sources.common.components")
local highlights = require("neo-tree.ui.highlights")

local M = {}

M.name = function(config, node, state)
  local res = common.name(config, node, state)
  if node:get_depth() == 1 then
    res.highlight = highlights.ROOT_NAME
  end
  return res
end

setmetatable(M, { __index = common })

return M
