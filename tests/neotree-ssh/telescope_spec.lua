local telescope_mod = require("neotree-ssh.telescope")
local source = require("neotree-ssh.source")
local cache = require("neotree-ssh.cache")
local main = require("neotree-ssh")

local function tempcache()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

describe("neotree-ssh.telescope helpers", function()
  it("_relpath strips the root prefix and leading slash", function()
    assert.equals("a/b.lua", telescope_mod._relpath("/srv/app", "/srv/app/a/b.lua"))
  end)

  it("_relpath returns absolute path when not under root", function()
    assert.equals("/other/x", telescope_mod._relpath("/srv/app", "/other/x"))
  end)

  it("_relpath handles root with trailing slash style input", function()
    assert.equals("a.lua", telescope_mod._relpath("/srv/app", "/srv/app/a.lua"))
  end)
end)

describe("neotree-ssh.telescope build_rg_cmd", function()
  it("produces a vimgrep command with smart-case by default", function()
    local cmd = telescope_mod.build_rg_cmd("foo", "/srv/app")
    assert.matches("^rg %-%-vimgrep ", cmd)
    assert.matches("%-%-no%-heading", cmd)
    assert.matches("%-%-smart%-case", cmd)
    assert.matches("'foo'", cmd)
    assert.matches("'/srv/app'", cmd)
  end)

  it("adds glob excludes prefixed with !", function()
    local cmd = telescope_mod.build_rg_cmd("foo", "/srv/app", { exclude = { ".git", "target" } })
    assert.matches("'!%.git'", cmd)
    assert.matches("'!target'", cmd)
  end)

  it("escapes single quotes in query", function()
    local cmd = telescope_mod.build_rg_cmd("it's", "/srv")
    assert.matches([['it'\'']], cmd)
  end)
end)

describe("neotree-ssh.telescope parse_rg_line", function()
  it("parses path:line:col:text", function()
    local r = telescope_mod.parse_rg_line("/srv/app/a.lua:42:7:local foo = 1")
    assert.equals("/srv/app/a.lua", r.path)
    assert.equals(42, r.lnum)
    assert.equals(7, r.col)
    assert.equals("local foo = 1", r.text)
  end)

  it("returns nil for non-matching lines", function()
    assert.is_nil(telescope_mod.parse_rg_line("just garbage"))
  end)

  it("preserves colons in match text", function()
    local r = telescope_mod.parse_rg_line("/x:1:1:a:b:c")
    assert.equals("a:b:c", r.text)
  end)
end)

describe("neotree-ssh.telescope files_entries", function()
  before_each(function()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
  end)

  it("builds an entry per cached path with relative display and ssh url", function()
    local entries = telescope_mod.files_entries("myhost", {
      "/srv/app/a.lua",
      "/srv/app/sub/b.lua",
    })
    assert.equals(2, #entries)
    assert.equals("a.lua", entries[1].display)
    assert.equals("sub/b.lua", entries[2].display)
    assert.equals("ssh:/myhost/srv/app/a.lua", entries[1].url)
    assert.equals("myhost", entries[1].host)
  end)

  it("returns empty list for empty paths", function()
    assert.same({}, telescope_mod.files_entries("myhost", {}))
  end)
end)

describe("neotree-ssh.telescope grep_entries", function()
  before_each(function()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
  end)

  it("parses lines and produces entries with file/lnum/col", function()
    local entries = telescope_mod.grep_entries("myhost", {
      "/srv/app/a.lua:5:3:hello",
      "/srv/app/b.lua:10:1:world",
      "garbage line",
    })
    assert.equals(2, #entries)
    assert.equals(5, entries[1].lnum)
    assert.equals(3, entries[1].col)
    assert.equals("ssh:/myhost/srv/app/a.lua", entries[1].url)
    assert.matches("a%.lua:5:3: hello", entries[1].display)
  end)
end)

describe("neotree-ssh.telescope files (cache integration)", function()
  local cache_dir
  before_each(function()
    cache_dir = tempcache()
    source._reset_connections()
    main.setup({
      cache_dir = cache_dir,
      cache_ttl = 3600,
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
    cache.write("myhost", { "/srv/app/x.lua", "/srv/app/y.lua" })
  end)

  it("the cache feeds files_entries with the right results", function()
    local paths = cache.read("myhost")
    local entries = telescope_mod.files_entries("myhost", paths)
    local displays = {}
    for _, e in ipairs(entries) do table.insert(displays, e.display) end
    table.sort(displays)
    assert.same({ "x.lua", "y.lua" }, displays)
  end)
end)

describe("neotree-ssh.telescope open_entry", function()
  before_each(function()
    source._reset_connections()
    main.setup({ hosts = { myhost = { remote_root = "/srv/app" } } })
    require("neotree-ssh.buffer").setup()
    source._set_connection("myhost", {
      exec = function(_, cmd, _opts)
        if cmd:match("^cat ") then
          return { stdout = "alpha\nbeta\ngamma\n", stderr = "", code = 0 }
        end
        return { stdout = "", stderr = "", code = 0 }
      end,
    })
  end)

  it("opens the buffer at the SSH url and jumps to lnum/col", function()
    telescope_mod.open_entry({
      url = "ssh:/myhost/srv/app/a.lua",
      host = "myhost",
      path = "/srv/app/a.lua",
      lnum = 2,
      col = 1,
    })
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("ssh:/myhost/srv/app/a.lua", vim.b[bufnr].neotree_ssh_url)
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(2, cursor[1])
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
