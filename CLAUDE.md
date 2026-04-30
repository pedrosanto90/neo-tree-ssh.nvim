# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `make test` — run the full plenary spec suite headlessly.
- `make test-file FILE=tests/neotree-ssh/<name>_spec.lua` — run a single spec.
- `NEOTREE_SSH_INTEGRATION=1 NEOTREE_SSH_TEST_HOST=localhost make test` — opt in to the real-SSH integration test (requires key-based ssh to the host).
- `NEOTREE_SSH_DEPS=/path/to/lazy` — override where `tests/minimal_init.lua` looks for `plenary.nvim`, `neo-tree.nvim`, `telescope.nvim`, etc. (defaults to `~/.local/share/nvim/lazy`).
- `make clean` — remove `.testcache`.

There is no separate lint step.

## Architecture

The plugin exposes a Neo-tree source plus Telescope pickers backed by a single multiplexed SSH connection per host. Layered, bottom-up:

1. **`ssh.lua`** — thin OO wrapper around `vim.system("ssh", ...)`. Builds args with `ControlMaster=auto` + `ControlPath` + `ControlPersist` so every subsequent command reuses the same socket. `:exec` retries once on transient errors (matched by `TRANSIENT_PATTERNS`) by tearing down the master via `ssh -O exit`. `BatchMode=yes` is the default — passwords are never prompted; key/agent auth only. Tests inject `opts._executor` to stub the network.
2. **`fs.lua`** — remote filesystem ops (`list_dir`, read/write/rename/mkdir/rm) implemented as remote shell commands run through an `ssh.lua` connection. `list_dir` uses a single `find -mindepth 1 -maxdepth 1 -printf` to return name/type/size/mtime in one round trip.
3. **`cache.lua`** — one-shot remote `find` whose result is stored at `<cache_dir>/<host>.list` (default cache_dir: `stdpath('cache')/neotree-ssh`). TTL governed by `cache_ttl`. Refreshed by `:NeotreeSshRefresh` or implicitly by Telescope.
4. **`buffer.lua`** — registers `BufReadCmd` / `BufWriteCmd` autocmds for the synthetic `ssh:/<host>/<path>` URL scheme. Reads via `cat`, writes by piping the buffer through `cat > path`. Detects binary files via NUL bytes and opens them read-only.
5. **`source/init.lua`** — the Neo-tree source. Implements `navigate`, `toggle_directory`, `refresh`, plus helpers `make_url` / `parse_url` for the `ssh:/<host>/<path>` scheme. Lazy-loads child directories on expand. Caches one `ssh.lua` connection per host in `M._connections` (cleared by `_reset_connections` in tests).
6. **`telescope.lua`** — `files` picker reads the cached find list directly; `live_grep` shells `rg --vimgrep` over SSH on each prompt change and parses the output back into Telescope entries.
7. **`init.lua`** — `setup()` resolves config (via `config.lua`'s validate + deepmerge against defaults), sets log level, ensures `cache_dir` exists, and installs the buffer autocmds. `open(host, sub_path)` dispatches to `neo-tree.command`.
8. **`plugin/neotree-ssh.lua`** — defines the four user commands (`:NeotreeSshOpen`, `:NeotreeSshFiles`, `:NeotreeSshGrep`, `:NeotreeSshRefresh`). Each completes against `list_hosts()`.

### Conventions worth knowing

- All remote paths are absolute and use `/`. URLs are always `ssh:/<host><abs-path>` (single slash after the scheme — `parse_url` and `make_url` enforce this).
- Per-host config (`hosts.<name>`) is validated by `config.lua`; `remote_root` is required, `host` defaults to the table key, `exclude` defaults to `_DEFAULT_EXCLUDE`. Tests can pass `host._executor` to stub SSH for that host.
- The Neo-tree source registers under the name `neo-tree-ssh.source` for consumers, but `M.name` inside the source module is `"neotree-ssh"` (used as the source key when calling `neo-tree.command.execute`).
- `init.lua` records the last opened SSH URL in `M._state.last_url`; `:NeotreeSshToggle` reopens it (avoids neo-tree falling back to the default `filesystem` source after closing the panel).
- Tests live in `tests/neotree-ssh/` mirroring `lua/neotree-ssh/`. They import `plenary.busted` and run sequentially. `tests/minimal_init.lua` prepends the cwd to rtp so `require("neotree-ssh.*")` resolves.
