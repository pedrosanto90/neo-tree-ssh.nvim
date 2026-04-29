local buffer = require("neotree-ssh.buffer")
local source = require("neotree-ssh.source")
local main = require("neotree-ssh")

local function make_fake_conn(read_results, write_recorder)
  local read_idx = 0
  return {
    exec = function(_, cmd, opts)
      if cmd:match("^cat > ") then
        if write_recorder then
          write_recorder.last_stdin = opts.stdin
          write_recorder.last_cmd = cmd
          write_recorder.calls = (write_recorder.calls or 0) + 1
        end
        return { stdout = "", stderr = "", code = (write_recorder and write_recorder.code) or 0 }
      end
      if cmd:match("^cat ") then
        read_idx = read_idx + 1
        local r = read_results[read_idx] or read_results[#read_results]
        return r or { stdout = "", stderr = "", code = 0 }
      end
      return { stdout = "", stderr = "", code = 0 }
    end,
  }
end

describe("neotree-ssh.buffer helpers", function()
  it("_content_to_lines splits on \\n and preserves trailing-newline flag", function()
    local lines, trailing = buffer._content_to_lines("a\nb\nc\n")
    assert.same({ "a", "b", "c" }, lines)
    assert.is_true(trailing)
  end)

  it("_content_to_lines without trailing newline", function()
    local lines, trailing = buffer._content_to_lines("a\nb")
    assert.same({ "a", "b" }, lines)
    assert.is_false(trailing)
  end)

  it("_content_to_lines on empty content", function()
    local lines, trailing = buffer._content_to_lines("")
    assert.same({}, lines)
    assert.is_false(trailing)
  end)

  it("_lines_to_content joins with \\n and respects trailing flag", function()
    assert.equals("a\nb\nc\n", buffer._lines_to_content({ "a", "b", "c" }, true))
    assert.equals("a\nb\nc", buffer._lines_to_content({ "a", "b", "c" }, false))
    assert.equals("", buffer._lines_to_content({}, true))
  end)

  it("_looks_binary detects NUL bytes", function()
    assert.is_true(buffer._looks_binary("hello\0world"))
    assert.is_false(buffer._looks_binary("hello world\nfoo"))
    assert.is_false(buffer._looks_binary(""))
  end)
end)

describe("neotree-ssh.buffer read_into_buffer", function()
  before_each(function()
    source._reset_connections()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
  end)

  it("populates buffer lines from remote content", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "line1\nline2\nline3\n", stderr = "", code = 0 } }))
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok = buffer.read_into_buffer(bufnr, "ssh:/myhost/srv/app/file.lua")
    assert.is_true(ok)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "line1", "line2", "line3" }, lines)
    assert.is_false(vim.bo[bufnr].modified)
    assert.equals("acwrite", vim.bo[bufnr].buftype)
    assert.equals("ssh:/myhost/srv/app/file.lua", vim.b[bufnr].neotree_ssh_url)
    assert.is_true(vim.b[bufnr].neotree_ssh_trailing_newline)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("preserves no-trailing-newline state", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "single line", stderr = "", code = 0 } }))
    local bufnr = vim.api.nvim_create_buf(false, true)
    buffer.read_into_buffer(bufnr, "ssh:/myhost/srv/app/file")
    assert.same({ "single line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.is_false(vim.b[bufnr].neotree_ssh_trailing_newline)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles empty file", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "", stderr = "", code = 0 } }))
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok = buffer.read_into_buffer(bufnr, "ssh:/myhost/srv/app/empty")
    assert.is_true(ok)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "" }, lines)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("marks binary files readonly with placeholder", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "ELF\0\0binary\0junk", stderr = "", code = 0 } }))
    local bufnr = vim.api.nvim_create_buf(false, true)
    buffer.read_into_buffer(bufnr, "ssh:/myhost/srv/app/bin")
    assert.is_true(vim.b[bufnr].neotree_ssh_binary)
    assert.is_false(vim.bo[bufnr].modifiable)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.matches("binary file", lines[1])
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns error for invalid url", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok, err = buffer.read_into_buffer(bufnr, "/not/an/ssh/url")
    assert.is_false(ok)
    assert.matches("invalid ssh url", err)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns error when remote read fails", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "", stderr = "No such file", code = 1 } }))
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok, err = buffer.read_into_buffer(bufnr, "ssh:/myhost/srv/app/nope")
    assert.is_false(ok)
    assert.matches("No such file", err)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("neotree-ssh.buffer write_from_buffer", function()
  before_each(function()
    source._reset_connections()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
  end)

  it("sends buffer content to remote via stdin", function()
    local recorder = {}
    source._set_connection("myhost", make_fake_conn({}, recorder))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "world" })
    vim.b[bufnr].neotree_ssh_trailing_newline = true
    local ok = buffer.write_from_buffer(bufnr, "ssh:/myhost/srv/app/file.txt")
    assert.is_true(ok)
    assert.equals("hello\nworld\n", recorder.last_stdin)
    assert.matches("'/srv/app/file%.txt'", recorder.last_cmd)
    assert.is_false(vim.bo[bufnr].modified)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("preserves no-trailing-newline when flag is false", function()
    local recorder = {}
    source._set_connection("myhost", make_fake_conn({}, recorder))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "no newline" })
    vim.b[bufnr].neotree_ssh_trailing_newline = false
    buffer.write_from_buffer(bufnr, "ssh:/myhost/srv/app/file")
    assert.equals("no newline", recorder.last_stdin)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("refuses to write binary buffers", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[bufnr].neotree_ssh_binary = true
    local ok, err = buffer.write_from_buffer(bufnr, "ssh:/myhost/srv/app/bin")
    assert.is_false(ok)
    assert.matches("binary", err)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("propagates remote write errors", function()
    local recorder = { code = 1 }
    source._set_connection("myhost", make_fake_conn({}, recorder))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
    local ok, err = buffer.write_from_buffer(bufnr, "ssh:/myhost/srv/app/file")
    assert.is_false(ok)
    assert.is_string(err)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("neotree-ssh.buffer setup autocmds", function()
  it("registers BufReadCmd for ssh:/* pattern", function()
    buffer.setup()
    local autocmds = vim.api.nvim_get_autocmds({ group = "NeotreeSshBuffer", event = "BufReadCmd" })
    assert.is_true(#autocmds > 0)
    local matches = false
    for _, a in ipairs(autocmds) do
      if a.pattern == "ssh:/*" then matches = true end
    end
    assert.is_true(matches)
  end)

  it("registers BufWriteCmd for ssh:/* pattern", function()
    buffer.setup()
    local autocmds = vim.api.nvim_get_autocmds({ group = "NeotreeSshBuffer", event = "BufWriteCmd" })
    local matches = false
    for _, a in ipairs(autocmds) do
      if a.pattern == "ssh:/*" then matches = true end
    end
    assert.is_true(matches)
  end)
end)

describe("neotree-ssh.buffer end-to-end via :edit", function()
  before_each(function()
    source._reset_connections()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
  end)

  it(":edit on an ssh url triggers BufReadCmd and loads content", function()
    local recorder = {}
    source._set_connection("myhost", make_fake_conn({ { stdout = "alpha\nbeta\n", stderr = "", code = 0 } }, recorder))
    vim.cmd("edit ssh:/myhost/srv/app/file.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "alpha", "beta" }, lines)
    assert.equals("ssh:/myhost/srv/app/file.lua", vim.b[bufnr].neotree_ssh_url)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it(":write on an ssh buffer triggers BufWriteCmd and sends content", function()
    local recorder = {}
    source._set_connection("myhost", make_fake_conn({ { stdout = "old\n", stderr = "", code = 0 } }, recorder))
    vim.cmd("edit ssh:/myhost/srv/app/save.txt")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
    vim.cmd("write")
    assert.equals("new content\n", recorder.last_stdin)
    assert.equals(1, recorder.calls)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
