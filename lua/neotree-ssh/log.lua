local M = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, off = 6 }

local current_level = LEVELS.info

local function emit(level_name, level_value, msg, ...)
  if level_value < current_level then
    return
  end
  local formatted = select("#", ...) > 0 and string.format(msg, ...) or msg
  local line = string.format("[neotree-ssh][%s] %s", level_name, formatted)
  if level_value >= LEVELS.warn then
    vim.schedule(function()
      vim.notify(line, level_value == LEVELS.warn and vim.log.levels.WARN or vim.log.levels.ERROR)
    end)
  else
    vim.schedule(function()
      vim.api.nvim_echo({ { line, "Comment" } }, false, {})
    end)
  end
end

function M.set_level(level)
  local v = LEVELS[level]
  if not v then
    error(string.format("invalid log level: %s", tostring(level)))
  end
  current_level = v
end

function M.get_level()
  for name, v in pairs(LEVELS) do
    if v == current_level then
      return name
    end
  end
end

function M.trace(msg, ...) emit("trace", LEVELS.trace, msg, ...) end
function M.debug(msg, ...) emit("debug", LEVELS.debug, msg, ...) end
function M.info(msg, ...)  emit("info",  LEVELS.info,  msg, ...) end
function M.warn(msg, ...)  emit("warn",  LEVELS.warn,  msg, ...) end
function M.error(msg, ...) emit("error", LEVELS.error, msg, ...) end

M._LEVELS = LEVELS

return M
