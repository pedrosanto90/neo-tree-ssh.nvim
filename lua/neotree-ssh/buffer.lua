local fs = require("neotree-ssh.fs")
local source = require("neotree-ssh.source")
local log = require("neotree-ssh.log")

local M = {}

local function content_to_lines(content)
  if content == "" then return {}, false end
  local trailing_newline = content:sub(-1) == "\n"
  if trailing_newline then content = content:sub(1, -2) end
  local lines = vim.split(content, "\n", { plain = true })
  return lines, trailing_newline
end
M._content_to_lines = content_to_lines

local function lines_to_content(lines, trailing_newline)
  local content = table.concat(lines, "\n")
  if trailing_newline and #lines > 0 then content = content .. "\n" end
  return content
end
M._lines_to_content = lines_to_content

local function looks_binary(content)
  if content == "" then return false end
  local sample = content:sub(1, 8000)
  return sample:find("\0", 1, true) ~= nil
end
M._looks_binary = looks_binary

function M.read_into_buffer(bufnr, url)
  local host_name, remote_path = source.parse_url(url)
  if not host_name then return false, "invalid ssh url: " .. tostring(url) end

  local conn, conn_err = source._get_conn(host_name)
  if not conn then return false, conn_err end

  local content, read_err = fs.read_file(conn, remote_path)
  if not content then return false, read_err end

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true

  if looks_binary(content) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[neotree-ssh] binary file: " .. remote_path })
    vim.b[bufnr].neotree_ssh_binary = true
    vim.b[bufnr].neotree_ssh_url = url
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    return true
  end

  local lines, trailing = content_to_lines(content)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].neotree_ssh_url = url
  vim.b[bufnr].neotree_ssh_trailing_newline = trailing
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].modifiable = was_modifiable
  return true
end

function M.write_from_buffer(bufnr, url)
  if vim.b[bufnr].neotree_ssh_binary then
    return false, "cannot write binary buffer"
  end
  local host_name, remote_path = source.parse_url(url)
  if not host_name then return false, "invalid ssh url: " .. tostring(url) end

  local conn, conn_err = source._get_conn(host_name)
  if not conn then return false, conn_err end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local trailing = vim.b[bufnr].neotree_ssh_trailing_newline
  if trailing == nil then trailing = true end
  local content = lines_to_content(lines, trailing)

  local ok, write_err = fs.write_file(conn, remote_path, content)
  if not ok then return false, write_err end

  vim.bo[bufnr].modified = false
  return true
end

function M.setup()
  local group = vim.api.nvim_create_augroup("NeotreeSshBuffer", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadCmd", "FileReadCmd" }, {
    group = group,
    pattern = "ssh:/*",
    callback = function(args)
      local ok, err = M.read_into_buffer(args.buf, args.match)
      if not ok then
        log.error("read %s failed: %s", args.match, tostring(err))
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
    group = group,
    pattern = "ssh:/*",
    callback = function(args)
      local ok, err = M.write_from_buffer(args.buf, args.match)
      if not ok then
        log.error("write %s failed: %s", args.match, tostring(err))
        return false
      end
    end,
  })
end

return M
