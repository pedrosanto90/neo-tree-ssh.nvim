local M = {}
M.__index = M

local function default_executor(args, opts)
  opts = opts or {}
  local sys_opts = {
    stdin = opts.stdin,
    timeout = opts.timeout,
    text = true,
  }
  if opts.async then
    local cb = opts.callback
    vim.system(args, sys_opts, function(result)
      vim.schedule(function()
        cb({
          stdout = result.stdout or "",
          stderr = result.stderr or "",
          code = result.code,
        })
      end)
    end)
    return nil
  end
  local r = vim.system(args, sys_opts):wait()
  return {
    stdout = r.stdout or "",
    stderr = r.stderr or "",
    code = r.code,
  }
end

local function build_ssh_args(opts, remote_cmd, control_action)
  local args = { "ssh" }

  if control_action then
    if opts.control_path then
      table.insert(args, "-o")
      table.insert(args, "ControlPath=" .. opts.control_path)
    end
    table.insert(args, "-O")
    table.insert(args, control_action)
    table.insert(args, opts.user and (opts.user .. "@" .. opts.host) or opts.host)
    return args
  end

  if opts.control_path then
    table.insert(args, "-o"); table.insert(args, "ControlMaster=auto")
    table.insert(args, "-o"); table.insert(args, "ControlPath=" .. opts.control_path)
    table.insert(args, "-o"); table.insert(args, "ControlPersist=" .. tostring(opts.control_persist or 600))
  end
  if opts.connect_timeout then
    table.insert(args, "-o"); table.insert(args, "ConnectTimeout=" .. tostring(opts.connect_timeout))
  end
  if opts.batch_mode ~= false then
    table.insert(args, "-o"); table.insert(args, "BatchMode=yes")
  end
  if opts.identity_file then
    table.insert(args, "-i"); table.insert(args, opts.identity_file)
  end
  if opts.port then
    table.insert(args, "-p"); table.insert(args, tostring(opts.port))
  end
  table.insert(args, opts.user and (opts.user .. "@" .. opts.host) or opts.host)
  if remote_cmd ~= nil then
    table.insert(args, "--")
    table.insert(args, remote_cmd)
  end
  return args
end

function M.new(opts)
  assert(type(opts) == "table", "ssh.new: opts must be a table")
  assert(type(opts.host) == "string" and opts.host ~= "", "ssh.new: host required")

  local self = setmetatable({}, M)
  self.opts = opts
  self._executor = opts._executor or default_executor

  if opts.control_path then
    local dir = vim.fn.fnamemodify(opts.control_path, ":h")
    if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p", tonumber("700", 8))
    end
  end
  return self
end

function M:_args(remote_cmd)
  return build_ssh_args(self.opts, remote_cmd, nil)
end

function M:_control_args(action)
  return build_ssh_args(self.opts, nil, action)
end

local TRANSIENT_PATTERNS = {
  "Connection closed",
  "Connection reset",
  "Broken pipe",
  "Connection refused",
  "no matching .* socket",
}

local function is_transient(result)
  if result.code == 0 then return false end
  local stderr = (result.stderr or ""):lower()
  if stderr == "" then return false end
  for _, pat in ipairs(TRANSIENT_PATTERNS) do
    if stderr:match(pat:lower()) then return true end
  end
  return false
end
M._is_transient = is_transient

function M:exec(remote_cmd, exec_opts)
  exec_opts = exec_opts or {}
  local result = self._executor(self:_args(remote_cmd), exec_opts)
  if exec_opts.no_retry or not is_transient(result) then
    return result
  end
  -- Tear down a potentially-stale master then retry once.
  if self.opts.control_path then
    pcall(self._executor, self:_control_args("exit"), {})
  end
  return self._executor(self:_args(remote_cmd), exec_opts)
end

function M:exec_async(remote_cmd, callback, exec_opts)
  exec_opts = exec_opts or {}
  exec_opts.async = true
  exec_opts.callback = callback
  return self._executor(self:_args(remote_cmd), exec_opts)
end

function M:is_alive()
  if not self.opts.control_path then return false end
  local r = self._executor(self:_control_args("check"), {})
  return r.code == 0
end

function M:disconnect()
  if not self.opts.control_path then return true end
  local r = self._executor(self:_control_args("exit"), {})
  return r.code == 0
end

function M:health()
  local r = self:exec("true")
  if r.code == 0 then
    return true, nil
  end
  local msg = r.stderr ~= "" and r.stderr or string.format("ssh exited with code %s", tostring(r.code))
  return false, msg
end

function M:connect()
  return self:health()
end

M._build_ssh_args = build_ssh_args
M._default_executor = default_executor

return M
