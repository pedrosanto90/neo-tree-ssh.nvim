local source = require("neotree-ssh.source")
local main = require("neotree-ssh")

local function make_fake_conn(list_dir_results)
  local idx = 0
  return {
    exec = function(_, cmd, _opts)
      idx = idx + 1
      local result = list_dir_results[idx] or list_dir_results[#list_dir_results]
      if type(result) == "function" then
        result = result(cmd)
      end
      return result or { stdout = "", stderr = "", code = 0 }
    end,
  }
end

local function rec(t, Y, size, mtime, name)
  return string.format("%s\t%s\t%d\t%s\t%s\0", t, Y, size, mtime, name)
end

describe("neotree-ssh.source URL helpers", function()
  it("make_url joins host and remote path with single slash", function()
    assert.equals("ssh:/myhost/srv/app", source.make_url("myhost", "/srv/app"))
  end)

  it("make_url adds leading slash when remote is missing it", function()
    assert.equals("ssh:/myhost/srv/app", source.make_url("myhost", "srv/app"))
  end)

  it("parse_url returns host and remote path", function()
    local h, p = source.parse_url("ssh:/myhost/srv/app")
    assert.equals("myhost", h)
    assert.equals("/srv/app", p)
  end)

  it("parse_url is idempotent across vim.fs.normalize", function()
    local url = source.make_url("myhost", "/srv/app/sub")
    local normalized = vim.fs.normalize(url)
    assert.equals(url, normalized)
    local h, p = source.parse_url(normalized)
    assert.equals("myhost", h)
    assert.equals("/srv/app/sub", p)
  end)

  it("parse_url returns nil for non-ssh paths", function()
    local h, p = source.parse_url("/srv/app")
    assert.is_nil(h)
    assert.is_nil(p)
  end)

  it("parse_url handles host-only url", function()
    local h, p = source.parse_url("ssh:/myhost")
    assert.equals("myhost", h)
    assert.equals("/", p)
  end)

  it("_join_remote produces clean child paths", function()
    assert.equals("/srv/app/file.lua", source._join_remote("/srv/app", "file.lua"))
    assert.equals("/file.lua", source._join_remote("/", "file.lua"))
  end)
end)

describe("neotree-ssh.source _build_dir", function()
  before_each(function()
    source._reset_connections()
    main.setup({
      hosts = {
        myhost = { remote_root = "/srv/app" },
      },
    })
  end)

  it("returns root with children of remote dir", function()
    local stdout = rec("d", "d", 4096, "1700000000", "src") ..
                   rec("f", "f", 50, "1700000000", "README.md") ..
                   rec("f", "f", 100, "1700000000", "main.lua")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))

    local root, count, err = source._build_dir("myhost", "/srv/app")
    assert.is_nil(err)
    assert.equals(3, count)
    assert.equals("ssh:/myhost/srv/app", root.id)
    assert.equals("directory", root.type)
    assert.equals(3, #root.children)

    local names = {}
    for _, c in ipairs(root.children) do table.insert(names, c.name) end
    table.sort(names)
    assert.same({ "README.md", "main.lua", "src" }, names)
  end)

  it("each child has the correct ssh URL as id", function()
    local stdout = rec("f", "f", 1, "1700000000", "a.txt")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))
    local root = source._build_dir("myhost", "/srv/app")
    assert.equals("ssh:/myhost/srv/app/a.txt", root.children[1].id)
  end)

  it("propagates host_name and remote_path in extra", function()
    local stdout = rec("d", "d", 4096, "1700000000", "src")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))
    local root = source._build_dir("myhost", "/srv/app")
    assert.equals("myhost", root.children[1].extra.host_name)
    assert.equals("/srv/app/src", root.children[1].extra.remote_path)
  end)

  it("marks directories as not-yet-loaded for lazy expansion", function()
    local stdout = rec("d", "d", 4096, "1700000000", "src") ..
                   rec("f", "f", 1, "1700000000", "x")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))
    local root = source._build_dir("myhost", "/srv/app")
    local dir, file
    for _, c in ipairs(root.children) do
      if c.type == "directory" then dir = c else file = c end
    end
    assert.is_false(dir.loaded)
    assert.is_nil(file.loaded)
  end)

  it("treats symlinks pointing to files as files", function()
    local stdout = rec("l", "f", 0, "1700000000", "linkfile")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))
    local root = source._build_dir("myhost", "/srv/app")
    assert.equals("file", root.children[1].type)
  end)

  it("treats symlinks pointing to directories as directories", function()
    local stdout = rec("l", "d", 0, "1700000000", "linkdir")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))
    local root = source._build_dir("myhost", "/srv/app")
    assert.equals("directory", root.children[1].type)
  end)

  it("returns error for unknown host", function()
    source._reset_connections()
    local _, _, err = source._build_dir("nope", "/srv/app")
    assert.is_string(err)
    assert.matches("unknown host", err)
  end)

  it("returns error when list_dir fails", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "", stderr = "Permission denied", code = 1 } }))
    local _, _, err = source._build_dir("myhost", "/root")
    assert.matches("Permission denied", err)
  end)

  it("handles empty directories", function()
    source._set_connection("myhost", make_fake_conn({ { stdout = "", stderr = "", code = 0 } }))
    local root, count, err = source._build_dir("myhost", "/empty")
    assert.is_nil(err)
    assert.equals(0, count)
    assert.equals(0, #root.children)
  end)
end)

describe("neotree-ssh.source navigate", function()
  local renderer = require("neo-tree.ui.renderer")
  local original_show

  before_each(function()
    original_show = renderer.show_nodes
    source._reset_connections()
    main.setup({
      hosts = { myhost = { remote_root = "/srv/app" } },
    })
  end)

  after_each(function()
    renderer.show_nodes = original_show
  end)

  it("populates state.path and calls renderer.show_nodes with the root", function()
    local stdout = rec("d", "d", 4096, "1700000000", "src")
    source._set_connection("myhost", make_fake_conn({ { stdout = stdout, stderr = "", code = 0 } }))

    local captured
    renderer.show_nodes = function(items, state, parent_id, _cb)
      captured = { items = items, state = state, parent_id = parent_id }
    end

    local state = {}
    source.navigate(state, "ssh:/myhost/srv/app")

    assert.equals("ssh:/myhost/srv/app", state.path)
    assert.is_table(captured)
    assert.equals(1, #captured.items)
    assert.equals("ssh:/myhost/srv/app", captured.items[1].id)
    assert.equals(1, #captured.items[1].children)
  end)

  it("does nothing when path is invalid", function()
    local called = false
    renderer.show_nodes = function() called = true end
    source.navigate({}, "/not/an/ssh/url")
    assert.is_false(called)
  end)
end)
