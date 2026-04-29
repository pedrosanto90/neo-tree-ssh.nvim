local config = require("neotree-ssh.config")

describe("neotree-ssh.config", function()
  describe("defaults()", function()
    it("returns a table with expected keys", function()
      local d = config.defaults()
      assert.is_table(d)
      assert.equals("info", d.log_level)
      assert.equals(600, d.control_persist)
      assert.equals(10, d.connect_timeout)
      assert.is_table(d.hosts)
    end)

    it("returns a fresh copy each time (no shared state)", function()
      local a = config.defaults()
      local b = config.defaults()
      a.hosts.fake = { remote_root = "/x" }
      assert.is_nil(b.hosts.fake)
    end)
  end)

  describe("resolve()", function()
    it("uses defaults when no user config given", function()
      local c = config.resolve()
      assert.equals("info", c.log_level)
    end)

    it("overrides scalar defaults from user config", function()
      local c = config.resolve({ log_level = "debug", connect_timeout = 30 })
      assert.equals("debug", c.log_level)
      assert.equals(30, c.connect_timeout)
    end)

    it("populates host.host from key when omitted", function()
      local c = config.resolve({
        hosts = { myhost = { remote_root = "/srv/app" } },
      })
      assert.equals("myhost", c.hosts.myhost.host)
      assert.equals("/srv/app", c.hosts.myhost.remote_root)
    end)

    it("preserves explicit host.host different from key", function()
      local c = config.resolve({
        hosts = { alias = { host = "real.example.com", remote_root = "/srv" } },
      })
      assert.equals("real.example.com", c.hosts.alias.host)
    end)

    it("applies default exclude list when missing", function()
      local c = config.resolve({
        hosts = { h = { remote_root = "/x" } },
      })
      assert.is_table(c.hosts.h.exclude)
      assert.is_true(vim.tbl_contains(c.hosts.h.exclude, ".git"))
      assert.is_true(vim.tbl_contains(c.hosts.h.exclude, "node_modules"))
    end)

    it("respects custom exclude list", function()
      local c = config.resolve({
        hosts = { h = { remote_root = "/x", exclude = { "only_this" } } },
      })
      assert.same({ "only_this" }, c.hosts.h.exclude)
    end)

    it("rejects invalid log_level", function()
      assert.has_error(function()
        config.resolve({ log_level = "bogus" })
      end)
    end)

    it("rejects host without remote_root", function()
      assert.has_error(function()
        config.resolve({ hosts = { bad = {} } })
      end)
    end)

    it("rejects non-positive connect_timeout", function()
      assert.has_error(function()
        config.resolve({ connect_timeout = 0 })
      end)
    end)

    it("rejects non-integer port", function()
      assert.has_error(function()
        config.resolve({ hosts = { h = { remote_root = "/x", port = 22.5 } } })
      end)
    end)
  end)

  describe("validate()", function()
    it("passes for a fully resolved minimal config", function()
      local c = config.resolve({})
      local ok, err = config.validate(c)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("fails for non-table input", function()
      local ok, err = config.validate("nope")
      assert.is_false(ok)
      assert.is_string(err)
    end)
  end)
end)
