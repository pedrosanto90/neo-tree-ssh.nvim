local ssh = require("neotree-ssh.ssh")

local function make_recorder(responses)
  local calls = {}
  local idx = 0
  local executor = function(args, opts)
    idx = idx + 1
    table.insert(calls, { args = args, opts = opts })
    local resp
    if type(responses) == "function" then
      resp = responses(args, opts, idx)
    elseif vim.islist(responses) then
      resp = responses[idx] or { stdout = "", stderr = "", code = 0 }
    else
      resp = responses or { stdout = "", stderr = "", code = 0 }
    end
    if opts.async then
      vim.schedule(function() opts.callback(resp) end)
      return nil
    end
    return resp
  end
  return executor, calls
end

describe("neotree-ssh.ssh", function()
  describe("argument construction", function()
    it("builds minimal args for a host with no extras", function()
      local conn = ssh.new({ host = "h1", _executor = function() return { stdout = "", stderr = "", code = 0 } end })
      local args = conn:_args("ls /tmp")
      assert.equals("ssh", args[1])
      assert.is_true(vim.tbl_contains(args, "h1"))
      assert.is_true(vim.tbl_contains(args, "ls /tmp"))
      assert.is_true(vim.tbl_contains(args, "--"))
      assert.is_true(vim.tbl_contains(args, "BatchMode=yes"))
    end)

    it("includes user@host when user is set", function()
      local conn = ssh.new({ host = "h1", user = "alice", _executor = function() end })
      local args = conn:_args("true")
      assert.is_true(vim.tbl_contains(args, "alice@h1"))
      assert.is_false(vim.tbl_contains(args, "h1"))
    end)

    it("adds port flag when set", function()
      local conn = ssh.new({ host = "h1", port = 2222, _executor = function() end })
      local args = conn:_args("true")
      local found = false
      for i, v in ipairs(args) do
        if v == "-p" and args[i + 1] == "2222" then found = true end
      end
      assert.is_true(found)
    end)

    it("adds identity_file with -i", function()
      local conn = ssh.new({ host = "h1", identity_file = "/tmp/id", _executor = function() end })
      local args = conn:_args("true")
      local found = false
      for i, v in ipairs(args) do
        if v == "-i" and args[i + 1] == "/tmp/id" then found = true end
      end
      assert.is_true(found)
    end)

    it("adds ControlMaster options when control_path is set", function()
      local conn = ssh.new({
        host = "h1",
        control_path = "/tmp/neotree-ssh-test/cm",
        control_persist = 300,
        _executor = function() end,
      })
      local args = conn:_args("true")
      assert.is_true(vim.tbl_contains(args, "ControlMaster=auto"))
      assert.is_true(vim.tbl_contains(args, "ControlPath=/tmp/neotree-ssh-test/cm"))
      assert.is_true(vim.tbl_contains(args, "ControlPersist=300"))
    end)

    it("adds ConnectTimeout when set", function()
      local conn = ssh.new({ host = "h1", connect_timeout = 7, _executor = function() end })
      local args = conn:_args("true")
      assert.is_true(vim.tbl_contains(args, "ConnectTimeout=7"))
    end)
  end)

  describe("control args", function()
    it("builds -O check args", function()
      local conn = ssh.new({
        host = "h1",
        control_path = "/tmp/neotree-ssh-test/cm",
        _executor = function() end,
      })
      local args = conn:_control_args("check")
      assert.is_true(vim.tbl_contains(args, "-O"))
      assert.is_true(vim.tbl_contains(args, "check"))
      assert.is_true(vim.tbl_contains(args, "ControlPath=/tmp/neotree-ssh-test/cm"))
    end)

    it("builds -O exit args", function()
      local conn = ssh.new({ host = "h1", _executor = function() end })
      local args = conn:_control_args("exit")
      assert.is_true(vim.tbl_contains(args, "exit"))
    end)
  end)

  describe("exec", function()
    it("returns executor result and records the call", function()
      local exec, calls = make_recorder({ stdout = "hello\n", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      local r = conn:exec("echo hello")
      assert.equals("hello\n", r.stdout)
      assert.equals(0, r.code)
      assert.equals(1, #calls)
      assert.is_true(vim.tbl_contains(calls[1].args, "echo hello"))
    end)

    it("propagates non-zero exit codes", function()
      local exec = make_recorder({ stdout = "", stderr = "boom", code = 7 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      local r = conn:exec("false")
      assert.equals(7, r.code)
      assert.equals("boom", r.stderr)
    end)

    it("forwards stdin in opts", function()
      local exec, calls = make_recorder({ stdout = "", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      conn:exec("cat", { stdin = "input data" })
      assert.equals("input data", calls[1].opts.stdin)
    end)
  end)

  describe("exec_async", function()
    it("invokes callback with result", function()
      local exec = make_recorder({ stdout = "ok", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      local got
      conn:exec_async("ls", function(r) got = r end)
      vim.wait(200, function() return got ~= nil end)
      assert.is_not_nil(got)
      assert.equals("ok", got.stdout)
    end)
  end)

  describe("health", function()
    it("returns true when remote command exits 0", function()
      local exec = make_recorder({ stdout = "", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      local ok, err = conn:health()
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false with stderr message on failure", function()
      local exec = make_recorder({ stdout = "", stderr = "Permission denied", code = 255 })
      local conn = ssh.new({ host = "h1", _executor = exec })
      local ok, err = conn:health()
      assert.is_false(ok)
      assert.matches("Permission denied", err)
    end)
  end)

  describe("transient retry", function()
    it("retries once when stderr matches Connection closed", function()
      local responses = {
        { stdout = "", stderr = "Connection closed by remote host", code = 255 },
        { stdout = "ok", stderr = "", code = 0 },
      }
      local idx = 0
      local exec_args = {}
      local executor = function(args, opts)
        idx = idx + 1
        table.insert(exec_args, args)
        return responses[idx] or { stdout = "", stderr = "", code = 0 }
      end
      local conn = ssh.new({ host = "h1", _executor = executor })
      local r = conn:exec("ls")
      assert.equals(0, r.code)
      assert.equals("ok", r.stdout)
      assert.equals(2, idx)
    end)

    it("does NOT retry on Permission denied", function()
      local idx = 0
      local executor = function()
        idx = idx + 1
        return { stdout = "", stderr = "Permission denied", code = 255 }
      end
      local conn = ssh.new({ host = "h1", _executor = executor })
      local r = conn:exec("ls")
      assert.equals(255, r.code)
      assert.equals(1, idx)
    end)

    it("no_retry option disables retry", function()
      local idx = 0
      local executor = function()
        idx = idx + 1
        return { stdout = "", stderr = "Connection closed", code = 255 }
      end
      local conn = ssh.new({ host = "h1", _executor = executor })
      conn:exec("ls", { no_retry = true })
      assert.equals(1, idx)
    end)

    it("tears down stale master before retry when control_path is set", function()
      local exit_called = false
      local main_calls = 0
      local executor = function(args, _opts)
        if vim.tbl_contains(args, "exit") and vim.tbl_contains(args, "-O") then
          exit_called = true
          return { stdout = "", stderr = "", code = 0 }
        end
        main_calls = main_calls + 1
        if main_calls == 1 then
          return { stdout = "", stderr = "Connection closed", code = 255 }
        end
        return { stdout = "ok", stderr = "", code = 0 }
      end
      local conn = ssh.new({
        host = "h1",
        control_path = "/tmp/neotree-ssh-test/cm",
        _executor = executor,
      })
      local r = conn:exec("ls")
      assert.is_true(exit_called)
      assert.equals(0, r.code)
    end)
  end)

  describe("is_alive / disconnect", function()
    it("is_alive returns false without control_path", function()
      local conn = ssh.new({ host = "h1", _executor = function() return { code = 0, stdout = "", stderr = "" } end })
      assert.is_false(conn:is_alive())
    end)

    it("is_alive runs -O check when control_path is set", function()
      local exec, calls = make_recorder({ stdout = "Master running", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", control_path = "/tmp/neotree-ssh-test/cm", _executor = exec })
      assert.is_true(conn:is_alive())
      assert.is_true(vim.tbl_contains(calls[1].args, "check"))
    end)

    it("disconnect runs -O exit", function()
      local exec, calls = make_recorder({ stdout = "Exit request sent.", stderr = "", code = 0 })
      local conn = ssh.new({ host = "h1", control_path = "/tmp/neotree-ssh-test/cm", _executor = exec })
      assert.is_true(conn:disconnect())
      assert.is_true(vim.tbl_contains(calls[1].args, "exit"))
    end)
  end)
end)

describe("neotree-ssh.ssh integration (opt-in)", function()
  local enabled = vim.env.NEOTREE_SSH_INTEGRATION == "1"
  local target = vim.env.NEOTREE_SSH_TEST_HOST or "localhost"

  it("can run `true` against a real host", function()
    if not enabled then
      pending("set NEOTREE_SSH_INTEGRATION=1 to enable")
      return
    end
    local cm = vim.fn.tempname()
    local conn = ssh.new({
      host = target,
      control_path = cm,
      control_persist = 5,
      connect_timeout = 5,
    })
    local ok, err = conn:health()
    if not ok then
      pending("ssh to " .. target .. " failed: " .. tostring(err))
      return
    end
    assert.is_true(conn:is_alive())
    conn:disconnect()
  end)
end)
