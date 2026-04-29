local cache = require("neotree-ssh.cache")
local source = require("neotree-ssh.source")
local main = require("neotree-ssh")

local function tempcache()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function nul_join(paths)
  local s = ""
  for _, p in ipairs(paths) do s = s .. p .. "\0" end
  return s
end

local function make_fake_conn(stdout, code)
  return {
    exec = function(_, cmd, _opts)
      return { stdout = stdout, stderr = "", code = code or 0, _last_cmd = cmd }
    end,
    last_cmd = nil,
  }
end

local function make_recorder(stdout, code)
  local rec = { calls = 0, last_cmd = nil }
  rec.exec = function(_, cmd, _opts)
    rec.calls = rec.calls + 1
    rec.last_cmd = cmd
    return { stdout = stdout, stderr = "", code = code or 0 }
  end
  return rec
end

describe("neotree-ssh.cache build_find_cmd", function()
  it("builds a find command with no excludes", function()
    local cmd = cache.build_find_cmd("/srv/app", {})
    assert.matches("^find '/srv/app'", cmd)
    assert.matches("-type f", cmd)
    assert.matches("-print0", cmd)
    assert.is_nil(cmd:match("-prune"))
  end)

  it("includes a prune clause for each excluded directory name", function()
    local cmd = cache.build_find_cmd("/srv/app", { ".git", "node_modules" })
    assert.matches("-prune", cmd)
    assert.matches("-name '%.git'", cmd)
    assert.matches("-name 'node_modules'", cmd)
  end)

  it("shell-quotes the root path", function()
    local cmd = cache.build_find_cmd("/has space", {})
    assert.matches("'/has space'", cmd)
  end)
end)

describe("neotree-ssh.cache _parse_paths", function()
  it("parses NUL-separated paths", function()
    local paths = cache._parse_paths("/a\0/b\0/c\0")
    assert.same({ "/a", "/b", "/c" }, paths)
  end)

  it("returns empty for empty input", function()
    assert.same({}, cache._parse_paths(""))
  end)

  it("handles paths with spaces", function()
    local paths = cache._parse_paths("/foo bar\0/baz qux\0")
    assert.same({ "/foo bar", "/baz qux" }, paths)
  end)
end)

describe("neotree-ssh.cache write/read/invalidate", function()
  local cache_dir
  before_each(function()
    cache_dir = tempcache()
    source._reset_connections()
    main.setup({
      cache_dir = cache_dir,
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
  end)

  it("writes paths to cache file and reads them back", function()
    local ok = cache.write("myhost", { "/srv/app/a.lua", "/srv/app/b.lua" })
    assert.is_true(ok)
    local paths, err = cache.read("myhost")
    assert.is_nil(err)
    assert.same({ "/srv/app/a.lua", "/srv/app/b.lua" }, paths)
  end)

  it("read returns nil + error when no cache exists", function()
    local paths, err = cache.read("nonexistent_host")
    assert.is_nil(paths)
    assert.is_string(err)
  end)

  it("invalidate deletes the cache file", function()
    cache.write("myhost", { "/srv/app/x.lua" })
    assert.is_true(cache.invalidate("myhost"))
    local paths = cache.read("myhost")
    assert.is_nil(paths)
  end)

  it("is_stale returns true when no cache exists", function()
    assert.is_true(cache.is_stale("myhost"))
  end)

  it("is_stale returns false right after write (within TTL)", function()
    cache.write("myhost", { "/x" })
    assert.is_false(cache.is_stale("myhost"))
  end)
end)

describe("neotree-ssh.cache refresh", function()
  local cache_dir
  before_each(function()
    cache_dir = tempcache()
    source._reset_connections()
    main.setup({
      cache_dir = cache_dir,
      hosts = { myhost = { remote_root = "/srv/app", exclude = { ".git" } } },
    })
  end)

  it("runs find on remote and writes the results", function()
    local conn = make_recorder(nul_join({ "/srv/app/a.lua", "/srv/app/b/c.lua" }))
    source._set_connection("myhost", conn)
    local paths, err = cache.refresh("myhost")
    assert.is_nil(err)
    assert.same({ "/srv/app/a.lua", "/srv/app/b/c.lua" }, paths)
    assert.matches("^find '/srv/app'", conn.last_cmd)
    assert.matches("-name '%.git'", conn.last_cmd)
    -- written to disk
    local cached = cache.read("myhost")
    assert.same(paths, cached)
  end)

  it("returns error for unknown host", function()
    local _, err = cache.refresh("nope")
    assert.matches("unknown host", err)
  end)

  it("returns error when find fails", function()
    source._set_connection("myhost", make_fake_conn("", 1))
    local paths, err = cache.refresh("myhost")
    assert.is_nil(paths)
    assert.is_string(err)
  end)
end)

describe("neotree-ssh.cache get (TTL behavior)", function()
  local cache_dir
  before_each(function()
    cache_dir = tempcache()
    source._reset_connections()
  end)

  it("returns cached paths without calling refresh when fresh", function()
    main.setup({
      cache_dir = cache_dir,
      cache_ttl = 3600,
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
    cache.write("myhost", { "/srv/app/cached.lua" })

    local conn = make_recorder("", 0)
    source._set_connection("myhost", conn)

    local paths = cache.get("myhost")
    assert.same({ "/srv/app/cached.lua" }, paths)
    assert.equals(0, conn.calls)
  end)

  it("force=true bypasses cache and refreshes", function()
    main.setup({
      cache_dir = cache_dir,
      cache_ttl = 3600,
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
    cache.write("myhost", { "/old" })

    local conn = make_recorder(nul_join({ "/new" }))
    source._set_connection("myhost", conn)

    local paths = cache.get("myhost", { force = true })
    assert.same({ "/new" }, paths)
    assert.equals(1, conn.calls)
  end)

  it("refreshes when cache is stale (ttl=0)", function()
    main.setup({
      cache_dir = cache_dir,
      cache_ttl = 0,
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
    cache.write("myhost", { "/stale" })

    local conn = make_recorder(nul_join({ "/fresh" }))
    source._set_connection("myhost", conn)

    local paths = cache.get("myhost")
    assert.same({ "/fresh" }, paths)
    assert.equals(1, conn.calls)
  end)
end)
