local fs = require("neotree-ssh.fs")

local function make_conn(handler)
  local calls = {}
  return {
    exec = function(_, cmd, opts)
      table.insert(calls, { cmd = cmd, opts = opts })
      return handler(cmd, opts, #calls)
    end,
    _calls = calls,
  }
end

local function rec(t, Y, size, mtime, name)
  return string.format("%s\t%s\t%d\t%s\t%s\0", t, Y, size, mtime, name)
end

describe("neotree-ssh.fs", function()
  describe("_shellquote", function()
    it("wraps simple strings in single quotes", function()
      assert.equals("'hello'", fs._shellquote("hello"))
    end)

    it("escapes embedded single quotes", function()
      assert.equals([['it'\''s']], fs._shellquote("it's"))
    end)

    it("handles paths with spaces and special chars", function()
      assert.equals([['/foo bar/$baz']], fs._shellquote("/foo bar/$baz"))
    end)
  end)

  describe("_parse_records", function()
    it("returns empty list for empty input", function()
      assert.same({}, fs._parse_records(""))
    end)

    it("parses a single file record", function()
      local out = rec("f", "f", 42, "1700000000", "readme.md")
      local entries = fs._parse_records(out)
      assert.equals(1, #entries)
      assert.equals("readme.md", entries[1].name)
      assert.equals("file", entries[1].type)
      assert.equals(42, entries[1].size)
      assert.equals(1700000000, entries[1].mtime)
      assert.is_false(entries[1].is_link)
    end)

    it("parses a directory record", function()
      local out = rec("d", "d", 4096, "1700000000", "src")
      local entries = fs._parse_records(out)
      assert.equals("directory", entries[1].type)
    end)

    it("parses a symlink with resolved type", function()
      local out = rec("l", "f", 0, "1700000000", "link-to-file")
      local entries = fs._parse_records(out)
      assert.equals("link", entries[1].type)
      assert.equals("file", entries[1].resolved_type)
      assert.is_true(entries[1].is_link)
    end)

    it("parses multiple records separated by NUL", function()
      local out = rec("d", "d", 4096, "1700000000", "src") ..
                  rec("f", "f", 100, "1700000000", "main.lua") ..
                  rec("f", "f", 50, "1700000000", "README")
      local entries = fs._parse_records(out)
      assert.equals(3, #entries)
    end)

    it("handles names with spaces", function()
      local out = rec("f", "f", 1, "1700000000", "file with spaces.txt")
      local entries = fs._parse_records(out)
      assert.equals("file with spaces.txt", entries[1].name)
    end)

    it("handles names with tabs in path (find emits literal name after last \\t)", function()
      local out = rec("f", "f", 1, "1700000000", "weird\tname")
      local entries = fs._parse_records(out)
      assert.equals("weird\tname", entries[1].name)
    end)

    it("handles fractional mtime values", function()
      local out = rec("f", "f", 1, "1700000000.5", "x")
      local entries = fs._parse_records(out)
      assert.equals(1700000000, entries[1].mtime)
    end)
  end)

  describe("list_dir", function()
    it("returns sorted entries (dirs before files)", function()
      local conn = make_conn(function()
        local out = rec("f", "f", 10, "1700000000", "a.txt") ..
                    rec("d", "d", 4096, "1700000000", "zdir") ..
                    rec("f", "f", 10, "1700000000", "b.txt")
        return { stdout = out, stderr = "", code = 0 }
      end)
      local entries, err = fs.list_dir(conn, "/srv/app")
      assert.is_nil(err)
      assert.equals(3, #entries)
      assert.equals("zdir", entries[1].name)
      assert.equals("a.txt", entries[2].name)
      assert.equals("b.txt", entries[3].name)
    end)

    it("shell-quotes the path argument", function()
      local conn = make_conn(function()
        return { stdout = "", stderr = "", code = 0 }
      end)
      fs.list_dir(conn, "/srv/has space")
      assert.matches("'/srv/has space'", conn._calls[1].cmd)
    end)

    it("returns error on non-zero exit", function()
      local conn = make_conn(function()
        return { stdout = "", stderr = "Permission denied", code = 1 }
      end)
      local entries, err = fs.list_dir(conn, "/root")
      assert.is_nil(entries)
      assert.matches("Permission denied", err)
    end)

    it("returns empty list for empty directory", function()
      local conn = make_conn(function()
        return { stdout = "", stderr = "", code = 0 }
      end)
      local entries = fs.list_dir(conn, "/empty")
      assert.same({}, entries)
    end)
  end)

  describe("stat", function()
    it("returns entry for existing path", function()
      local conn = make_conn(function()
        return { stdout = rec("f", "f", 99, "1700000000", "file.txt"), stderr = "", code = 0 }
      end)
      local entry = fs.stat(conn, "/srv/file.txt")
      assert.equals("file.txt", entry.name)
      assert.equals(99, entry.size)
    end)

    it("returns nil + error for missing path", function()
      local conn = make_conn(function()
        return { stdout = "", stderr = "", code = 1 }
      end)
      local entry, err = fs.stat(conn, "/nope")
      assert.is_nil(entry)
      assert.is_string(err)
    end)
  end)

  describe("read_file / write_file", function()
    it("read_file returns stdout on success", function()
      local conn = make_conn(function()
        return { stdout = "file contents\n", stderr = "", code = 0 }
      end)
      local content = fs.read_file(conn, "/srv/x")
      assert.equals("file contents\n", content)
    end)

    it("read_file returns nil + err on failure", function()
      local conn = make_conn(function()
        return { stdout = "", stderr = "No such file", code = 1 }
      end)
      local content, err = fs.read_file(conn, "/nope")
      assert.is_nil(content)
      assert.matches("No such file", err)
    end)

    it("write_file passes content via stdin", function()
      local conn = make_conn(function(_, opts)
        return { stdout = "", stderr = "", code = opts.stdin == "hello world" and 0 or 1 }
      end)
      local ok = fs.write_file(conn, "/srv/x", "hello world")
      assert.is_true(ok)
      assert.equals("hello world", conn._calls[1].opts.stdin)
    end)
  end)

  describe("mkdir / rm / rename", function()
    it("mkdir builds plain mkdir cmd", function()
      local conn = make_conn(function() return { stdout = "", stderr = "", code = 0 } end)
      fs.mkdir(conn, "/srv/new")
      assert.matches("^mkdir '/srv/new'$", conn._calls[1].cmd)
    end)

    it("mkdir with parents adds -p", function()
      local conn = make_conn(function() return { stdout = "", stderr = "", code = 0 } end)
      fs.mkdir(conn, "/srv/a/b/c", { parents = true })
      assert.matches("^mkdir %-p ", conn._calls[1].cmd)
    end)

    it("rm without recursive uses -f only", function()
      local conn = make_conn(function() return { stdout = "", stderr = "", code = 0 } end)
      fs.rm(conn, "/srv/x")
      assert.matches("^rm %-f ", conn._calls[1].cmd)
      assert.is_nil(conn._calls[1].cmd:match("%-rf"))
    end)

    it("rm with recursive uses -rf", function()
      local conn = make_conn(function() return { stdout = "", stderr = "", code = 0 } end)
      fs.rm(conn, "/srv/dir", { recursive = true })
      assert.matches("^rm %-rf ", conn._calls[1].cmd)
    end)

    it("rename builds mv cmd with both quoted args", function()
      local conn = make_conn(function() return { stdout = "", stderr = "", code = 0 } end)
      fs.rename(conn, "/srv/a", "/srv/b")
      assert.matches("^mv '/srv/a' '/srv/b'$", conn._calls[1].cmd)
    end)
  end)
end)
