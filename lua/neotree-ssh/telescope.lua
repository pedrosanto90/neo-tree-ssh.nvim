local cache = require("neotree-ssh.cache")
local source = require("neotree-ssh.source")
local fs = require("neotree-ssh.fs")
local log = require("neotree-ssh.log")

local M = {}

local function shellquote(s)
  return "'" .. (s:gsub("'", [['\'']])) .. "'"
end

---Make a relative path from root, fall back to the absolute path.
local function relpath(root, path)
  if path:sub(1, #root) == root then
    local rel = path:sub(#root + 1)
    if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
    return rel
  end
  return path
end
M._relpath = relpath

---Build the ripgrep command run on the remote host.
---Format `path:line:col:text` (vimgrep) is what we parse.
function M.build_rg_cmd(query, root, opts)
  opts = opts or {}
  local parts = { "rg", "--vimgrep", "--no-heading", "--color=never" }
  if opts.smart_case ~= false then table.insert(parts, "--smart-case") end
  for _, name in ipairs(opts.exclude or {}) do
    table.insert(parts, "--glob")
    table.insert(parts, shellquote("!" .. name))
  end
  table.insert(parts, "--")
  table.insert(parts, shellquote(query))
  table.insert(parts, shellquote(root))
  return table.concat(parts, " ")
end

---Parse a single rg --vimgrep line: path:line:col:text
function M.parse_rg_line(line)
  local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
  if not path then return nil end
  return {
    path = path,
    lnum = tonumber(lnum),
    col = tonumber(col),
    text = text,
  }
end

---Build the entries Telescope shows for `ssh_files`.
function M.files_entries(host_name, paths)
  local cfg = require("neotree-ssh").get_config()
  local host_cfg = cfg.hosts[host_name] or { remote_root = "/" }
  local entries = {}
  for _, path in ipairs(paths) do
    table.insert(entries, {
      value = path,
      display = relpath(host_cfg.remote_root, path),
      ordinal = path,
      host = host_name,
      path = path,
      url = source.make_url(host_name, path),
    })
  end
  return entries
end

---Build the entries Telescope shows for `ssh_live_grep`.
function M.grep_entries(host_name, lines)
  local cfg = require("neotree-ssh").get_config()
  local host_cfg = cfg.hosts[host_name] or { remote_root = "/" }
  local entries = {}
  for _, line in ipairs(lines) do
    local parsed = M.parse_rg_line(line)
    if parsed then
      table.insert(entries, {
        value = parsed.path,
        display = string.format("%s:%d:%d: %s",
          relpath(host_cfg.remote_root, parsed.path), parsed.lnum, parsed.col, parsed.text),
        ordinal = parsed.path .. ":" .. parsed.text,
        host = host_name,
        path = parsed.path,
        lnum = parsed.lnum,
        col = parsed.col,
        text = parsed.text,
        url = source.make_url(host_name, parsed.path),
      })
    end
  end
  return entries
end

---Open the entry: :edit ssh:/.../ and jump to (lnum, col) when present.
function M.open_entry(entry)
  if not entry or not entry.url then return end
  vim.cmd("edit " .. vim.fn.fnameescape(entry.url))
  if entry.lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, math.max(0, (entry.col or 1) - 1) })
  end
end

local function ok_require(mod)
  local ok, m = pcall(require, mod)
  if ok then return m end
  return nil
end

local function need_telescope()
  return assert(ok_require("telescope.pickers"), "telescope.nvim is not installed"),
         assert(ok_require("telescope.finders"), "telescope.nvim is not installed"),
         assert(ok_require("telescope.config"), "telescope.nvim is not installed").values,
         assert(ok_require("telescope.actions"), "telescope.nvim is not installed"),
         assert(ok_require("telescope.actions.state"), "telescope.nvim is not installed"),
         ok_require("telescope.previewers")
end

local function preview_remote_file(self, entry)
  if not entry or not entry.host then return end
  local conn = source._get_conn(entry.host)
  if not conn then return end
  local content = fs.read_file(conn, entry.path)
  if not content then return end
  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
  if entry.lnum then
    pcall(vim.api.nvim_win_set_cursor, self.state.winid, { entry.lnum, 0 })
  end
end

function M.files(host_name, opts)
  opts = opts or {}
  local pickers, finders, conf, actions, action_state, previewers = need_telescope()

  local paths, err = cache.get(host_name, { force = opts.force })
  if not paths then
    log.error("ssh_files: %s", tostring(err))
    return
  end

  local previewer = previewers and previewers.new_buffer_previewer({
    title = "SSH Preview",
    define_preview = preview_remote_file,
  })

  pickers.new(opts, {
    prompt_title = "SSH Files (" .. host_name .. ")",
    finder = finders.new_table({
      results = M.files_entries(host_name, paths),
      entry_maker = function(e) return e end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        M.open_entry(entry)
      end)
      return true
    end,
  }):find()
end

function M.live_grep(host_name, opts)
  opts = opts or {}
  local pickers, finders, conf, actions, action_state, previewers = need_telescope()

  local cfg = require("neotree-ssh").get_config()
  local host_cfg = cfg.hosts[host_name]
  if not host_cfg then
    log.error("ssh_live_grep: unknown host %q", host_name)
    return
  end
  local conn = source._get_conn(host_name)
  if not conn then return end

  local previewer = previewers and previewers.new_buffer_previewer({
    title = "SSH Preview",
    define_preview = preview_remote_file,
  })

  local finder = finders.new_dynamic({
    fn = function(prompt)
      if not prompt or #prompt < 2 then return {} end
      local cmd = M.build_rg_cmd(prompt, host_cfg.remote_root, { exclude = host_cfg.exclude })
      local r = conn:exec(cmd, { timeout = opts.timeout })
      if r.code ~= 0 and r.code ~= 1 then
        return {}
      end
      local lines = vim.split(r.stdout, "\n", { plain = true })
      return M.grep_entries(host_name, lines)
    end,
    entry_maker = function(e) return e end,
  })

  pickers.new(opts, {
    prompt_title = "SSH Live Grep (" .. host_name .. ")",
    finder = finder,
    sorter = conf.generic_sorter(opts),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        M.open_entry(entry)
      end)
      return true
    end,
  }):find()
end

return M
