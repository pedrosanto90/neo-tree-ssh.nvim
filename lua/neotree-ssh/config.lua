local M = {}

local DEFAULT_EXCLUDE = {
  ".git",
  "node_modules",
  ".venv",
  "venv",
  "__pycache__",
  "target",
  "dist",
  "build",
}

local defaults = {
  log_level = "info",
  control_path = vim.fn.stdpath("cache") .. "/neotree-ssh/cm-%h-%p-%r",
  control_persist = 600,
  connect_timeout = 10,
  cache_dir = vim.fn.stdpath("cache") .. "/neotree-ssh",
  cache_ttl = 3600,
  hosts = {},
}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end

local function deepmerge(base, override)
  local out = deepcopy(base)
  for k, v in pairs(override or {}) do
    if type(v) == "table" and type(out[k]) == "table" and not vim.islist(v) then
      out[k] = deepmerge(out[k], v)
    else
      out[k] = deepcopy(v)
    end
  end
  return out
end

local VALID_LOG_LEVELS = { trace = true, debug = true, info = true, warn = true, error = true, off = true }

local function validate_host(name, host)
  if type(host) ~= "table" then
    return string.format("host %q: must be a table", name)
  end
  if type(host.remote_root) ~= "string" or host.remote_root == "" then
    return string.format("host %q: remote_root is required (non-empty string)", name)
  end
  if host.host ~= nil and type(host.host) ~= "string" then
    return string.format("host %q: host must be string", name)
  end
  if host.user ~= nil and type(host.user) ~= "string" then
    return string.format("host %q: user must be string", name)
  end
  if host.port ~= nil and (type(host.port) ~= "number" or host.port <= 0 or host.port % 1 ~= 0) then
    return string.format("host %q: port must be positive integer", name)
  end
  if host.identity_file ~= nil and type(host.identity_file) ~= "string" then
    return string.format("host %q: identity_file must be string", name)
  end
  if host.exclude ~= nil and not vim.islist(host.exclude) then
    return string.format("host %q: exclude must be a list", name)
  end
  return nil
end

function M.validate(cfg)
  if type(cfg) ~= "table" then
    return false, "config must be a table"
  end
  if not VALID_LOG_LEVELS[cfg.log_level] then
    return false, string.format("invalid log_level: %s", tostring(cfg.log_level))
  end
  if type(cfg.control_persist) ~= "number" or cfg.control_persist <= 0 then
    return false, "control_persist must be a positive number"
  end
  if type(cfg.connect_timeout) ~= "number" or cfg.connect_timeout <= 0 then
    return false, "connect_timeout must be a positive number"
  end
  if type(cfg.cache_ttl) ~= "number" or cfg.cache_ttl < 0 then
    return false, "cache_ttl must be a non-negative number"
  end
  if type(cfg.hosts) ~= "table" then
    return false, "hosts must be a table"
  end
  for name, host in pairs(cfg.hosts) do
    local err = validate_host(name, host)
    if err then return false, err end
  end
  return true, nil
end

function M.defaults()
  return deepcopy(defaults)
end

function M.resolve(user_cfg)
  local merged = deepmerge(defaults, user_cfg or {})
  for name, host in pairs(merged.hosts) do
    host.host = host.host or name
    host.exclude = host.exclude or deepcopy(DEFAULT_EXCLUDE)
  end
  local ok, err = M.validate(merged)
  if not ok then
    error("neotree-ssh config: " .. err)
  end
  return merged
end

M._DEFAULT_EXCLUDE = DEFAULT_EXCLUDE
M._deepmerge = deepmerge

return M
