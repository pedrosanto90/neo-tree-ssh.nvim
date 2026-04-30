describe("neotree-ssh.init", function()
  local main
  local captured

  before_each(function()
    captured = {}
    package.loaded["neo-tree.command"] = {
      execute = function(opts)
        table.insert(captured, opts)
      end,
    }
    main = require("neotree-ssh")
    main._reset_state()
    main.setup({ hosts = { h1 = { remote_root = "/srv" } } })
  end)

  after_each(function()
    package.loaded["neo-tree.command"] = nil
  end)

  it("open(host) records last_url and dispatches to neo-tree", function()
    assert.is_true(main.open("h1"))
    assert.equals(1, #captured)
    assert.equals("neotree-ssh", captured[1].source)
    assert.equals("ssh:/h1/srv", captured[1].dir)
    assert.equals("ssh:/h1/srv", main.last_url())
  end)

  it("open(host, sub_path) records the sub_path URL", function()
    assert.is_true(main.open("h1", "/var/log"))
    assert.equals("ssh:/h1/var/log", main.last_url())
  end)

  it("open(unknown_host) returns false and leaves last_url nil", function()
    assert.is_false(main.open("desconhecido"))
    assert.equals(0, #captured)
    assert.is_nil(main.last_url())
  end)

  it("toggle() without prior open returns false", function()
    assert.is_false(main.toggle())
    assert.equals(0, #captured)
  end)

  it("toggle() reopens the last SSH URL", function()
    assert.is_true(main.open("h1", "/x"))
    assert.is_true(main.toggle())
    local last = captured[#captured]
    assert.equals("neotree-ssh", last.source)
    assert.equals("ssh:/h1/x", last.dir)
  end)
end)
