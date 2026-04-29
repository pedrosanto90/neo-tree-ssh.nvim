# neotree-ssh

A neo-tree source plus Telescope pickers that let you browse and edit files on a
remote SSH host as if the project were checked out locally — without the
overhead of `sshfs` or the navigation limitations of `oil-ssh`.

The plugin uses a multiplexed SSH connection (`ControlMaster=auto`) so every
operation reuses the same socket, and caches a one-shot `find` listing so that
Telescope's file picker stays responsive on large repositories.

## Requirements

- Neovim 0.10+
- `ssh`, `cat`, `mv`, `mkdir`, `rm`, `find` available on the remote host
- [`neo-tree.nvim`](https://github.com/nvim-neo-tree/neo-tree.nvim) (with its
  own dependencies: `nui.nvim`, `plenary.nvim`)
- [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) (optional,
  only required for the file/grep pickers)
- `ripgrep` on the remote host (only required for `:NeotreeSshGrep`)

## Install (lazy.nvim)

```lua
{
  "pedrosanto90/neo-tree-ssh",
  dependencies = {
    "nvim-neo-tree/neo-tree.nvim",
    "nvim-telescope/telescope.nvim",
  },
  opts = {
    log_level = "info",
    cache_ttl = 3600,
    hosts = {
      myhost = {
        host = "myhost",            -- alias from ~/.ssh/config or full hostname
        remote_root = "/srv/app",   -- required
        -- user = "deploy",
        -- port = 22,
        -- identity_file = "~/.ssh/id_rsa",
        -- exclude = { ".git", "node_modules", "target" },
      },
    },
  },
}
```

You also need to register the source with `neo-tree`:

```lua
require("neo-tree").setup({
  sources = { "filesystem", "buffers", "git_status", "neo-tree-ssh.source" },
})
```

## Usage

```vim
:NeotreeSshOpen myhost          " open the tree at the host's remote_root
:NeotreeSshOpen myhost /sub     " open the tree at a sub-path

:NeotreeSshFiles myhost         " telescope file picker (uses cached find)
:NeotreeSshGrep  myhost         " telescope live grep (rg over SSH)

:NeotreeSshRefresh myhost       " rebuild the file cache
```

Pressing Enter on a file in the tree opens it via `:edit ssh:/<host>/<path>`,
which the plugin handles transparently with `BufReadCmd` / `BufWriteCmd`. You
can keep using `:w`, `:saveas`, etc. as you would on a local file.

## How it works

- **Connection layer.** Every command runs through a long-lived
  `ControlMaster=auto` socket (`ControlPersist` defaults to 600s), so latency
  is dominated by the remote command itself, not by re-handshaking.
- **Tree.** A custom neo-tree source walks the remote filesystem one
  directory at a time. Each `find -mindepth 1 -maxdepth 1 -printf ...` call
  returns the entries with type, size and mtime in a single round trip.
- **Buffers.** Files appear under the synthetic scheme `ssh:/<host>/<path>`.
  `BufReadCmd` shells `cat` over the master socket; `BufWriteCmd` pipes the
  buffer content via `cat > path`. Binary files are detected via NUL bytes
  and opened read-only with a placeholder.
- **Telescope file picker.** A one-shot remote `find` is cached at
  `~/.cache/nvim/neotree-ssh/<host>.list`. The picker reads that file
  directly, so completion stays instant even for repositories with
  hundreds of thousands of files.
- **Telescope live grep.** Each prompt change runs `rg --vimgrep` over SSH
  on the remote host and parses the response back into Telescope entries.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `Permission denied` on every command | Identity file isn't in `~/.ssh/agent` or under `identity_file`; set up `~/.ssh/config` so that `ssh <host> true` works from a plain shell. |
| Tree opens but is empty | `remote_root` doesn't exist on the host, or `find` is missing. Run `:NeotreeSshRefresh <host>` and check `:messages`. |
| Telescope picker is slow on first open | The cache is being built. Run `:NeotreeSshRefresh <host>` ahead of time, or lower `cache_ttl` so it stays warm. |
| `:NeotreeSshGrep` returns nothing | `rg` isn't installed on the remote host. Install ripgrep or use plain `grep -Rn` via a custom command. |

The plugin uses a `BatchMode=yes` SSH option by default — passwords don't
work; use SSH keys or an agent.

## Development

```bash
make test               # run all specs
make test-file FILE=tests/neotree-ssh/source_spec.lua

NEOTREE_SSH_INTEGRATION=1 NEOTREE_SSH_TEST_HOST=localhost make test
```

The test suite uses [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
and stubs the SSH executor so tests run without network access. The opt-in
integration test connects to `localhost` (or `$NEOTREE_SSH_TEST_HOST`) and
verifies a real ControlMaster session.
