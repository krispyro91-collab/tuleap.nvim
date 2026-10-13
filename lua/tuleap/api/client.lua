---@mod tuleap.api.client Low level REST client
---
--- Every call is asynchronous and takes a `cb(err, data, meta)` callback that is
--- always invoked on the main loop, so callers may touch the Neovim API
--- directly. `err` is nil on success and a human readable string otherwise.
---
--- Authentication uses a Tuleap *personal access key* sent in the
--- `X-Auth-AccessKey` header, which is the supported scheme since Tuleap 11.

local config = require("tuleap.config")
local cache = require("tuleap.cache")
local log = require("tuleap.util.log")

local M = {}

M.API_PREFIX = "/api/v1"

---@param value any
---@return string
local function encode_component(value)
  if type(value) == "table" then
    value = vim.json.encode(value)
  elseif type(value) == "boolean" then
    value = value and "true" or "false"
  end
  return (vim.uri_encode(tostring(value), "rfc2396"))
end

--- Build "?a=1&b=2" with deterministic ordering so cache keys are stable.
---@param query table<string, any>?
---@return string
local function build_query(query)
  if not query or vim.tbl_isempty(query) then
    return ""
  end
  local keys = vim.tbl_keys(query)
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = query[key]
    if value ~= nil then
      parts[#parts + 1] = ("%s=%s"):format(encode_component(key), encode_component(value))
    end
  end
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

---@param path string
---@param query table?
---@return string
function M.url(path, query)
  local base = config.url() or ""
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  if not path:match("^/api") then
    path = M.API_PREFIX .. path
  end
  return base .. path .. build_query(query)
end

---@return table<string,string>
local function headers()
  local out = vim.tbl_extend("force", {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
    ["X-Auth-AccessKey"] = config.token() or "",
  }, config.options.request.extra_headers or {})
  return out
end

--- plenary returns headers as raw lines; fold them into a lowercase map.
---@param raw string[]|table|nil
---@return table<string,string>
local function parse_headers(raw)
  local out = {}
  if type(raw) ~= "table" then
    return out
  end
  for _, line in ipairs(raw) do
    if type(line) == "string" then
      local name, value = line:match("^([%w%-_]+):%s*(.*)$")
      if name then
        out[name:lower()] = vim.trim(value)
      end
    end
  end
  return out
end

---@param body string?
---@return any?
local function decode(body)
  if not body or vim.trim(body) == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    return nil
  end
  return decoded
end

--- Turn a non-2xx response into a readable message. Tuleap answers with
--- `{"error": {"code": 400, "message": "..."}}` on most failures.
---@param res table
---@return string
local function format_error(res)
  local status = res.status or 0
  local payload = decode(res.body)
  local detail
  if type(payload) == "table" then
    if type(payload.error) == "table" then
      detail = payload.error.message or payload.error.i18n_error_message
    elseif type(payload.error) == "string" then
      detail = payload.error
    end
  end
  if not detail and type(res.body) == "string" and #res.body > 0 then
    detail = vim.trim(res.body:sub(1, 300))
  end

  local hint = ({
    [401] = "check that $" .. config.options.env.token .. " holds a valid personal access key",
    [403] = "the access key lacks the required scope, or you are not a member of the project",
    [404] = "unknown id, or the REST route is not available on this Tuleap version",
    [429] = "Tuleap is rate limiting this endpoint, retry later",
  })[status]

  local msg = ("HTTP %d"):format(status)
  if detail then
    msg = msg .. ": " .. detail
  end
  if hint then
    msg = msg .. (" (%s)"):format(hint)
  end
  return msg
end

---@class tuleap.RequestOpts
---@field method string? GET by default
---@field path string REST path, with or without the /api/v1 prefix
---@field query table? query string parameters
---@field body table|string? JSON encoded when it is a table
---@field cache_ttl number? cache successful GETs for this many seconds
---@field raw boolean? return the body as a string instead of decoding it

--- Perform a single request.
---@param opts tuleap.RequestOpts
---@param cb fun(err: string?, data: any?, meta: table?)
function M.request(opts, cb)
  cb = cb or function() end
  local ok, err = config.validate()
  if not ok then
    return vim.schedule(function()
      cb(err)
    end)
  end

  local method = (opts.method or "GET"):upper()
  local url = M.url(opts.path, opts.query)
  local cache_key = cache.key({ method, url })

  if method == "GET" and opts.cache_ttl ~= 0 then
    local hit = cache.get(cache_key)
    if hit ~= nil then
      return vim.schedule(function()
        cb(nil, hit.data, hit.meta)
      end)
    end
  end

  local body = opts.body
  if type(body) == "table" then
    body = vim.json.encode(body)
  end

  log.dev("%s %s%s", method, url, body and (" " .. body) or "")

  local request = {
    url = url,
    method = method:lower(),
    headers = headers(),
    body = body,
    timeout = config.options.request.timeout,
    insecure = config.options.request.insecure,
    proxy = config.options.request.proxy,
    compressed = true,
    callback = function(res)
      vim.schedule(function()
        if not res or res.exit ~= nil and res.exit ~= 0 and not res.status then
          return cb(("curl failed (exit %s) for %s"):format(tostring(res and res.exit), url))
        end
        local status = res.status or 0
        if status < 200 or status >= 300 then
          log.dev("  -> %s", format_error(res))
          return cb(format_error(res))
        end
        local meta = { status = status, headers = parse_headers(res.headers) }
        meta.total = tonumber(meta.headers["x-pagination-size"])
        meta.limit_max = tonumber(meta.headers["x-pagination-limit-max"])
        local data = opts.raw and res.body or decode(res.body)
        if method == "GET" and opts.cache_ttl ~= 0 then
          cache.set(cache_key, { data = data, meta = meta }, opts.cache_ttl)
        end
        cb(nil, data, meta)
      end)
    end,
  }

  local curl_ok, curl = pcall(require, "plenary.curl")
  if not curl_ok then
    return vim.schedule(function()
      cb("plenary.nvim is required by tuleap.nvim but could not be loaded")
    end)
  end

  local sent, send_err = pcall(curl.request, request)
  if not sent then
    vim.schedule(function()
      cb(("request failed: %s"):format(send_err))
    end)
  end
end

---@param path string
---@param query table?
---@param cb fun(err: string?, data: any?, meta: table?)
---@param extra tuleap.RequestOpts?
function M.get(path, query, cb, extra)
  local opts = vim.tbl_extend("force", { path = path, query = query, method = "GET" }, extra or {})
  M.request(opts, cb)
end

---@param path string
---@param body table
---@param cb fun(err: string?, data: any?, meta: table?)
function M.post(path, body, cb)
  M.request({ path = path, body = body, method = "POST" }, cb)
end

---@param path string
---@param body table
---@param cb fun(err: string?, data: any?, meta: table?)
function M.put(path, body, cb)
  M.request({ path = path, body = body, method = "PUT" }, cb)
end

---@param path string
---@param cb fun(err: string?, data: any?, meta: table?)
function M.delete(path, cb)
  M.request({ path = path, method = "DELETE" }, cb)
end

--- Walk a paginated collection until it is exhausted (or `max_pages` is hit)
--- and hand the concatenated list to the callback.
---@param path string
---@param query table?
---@param cb fun(err: string?, items: any[]?, meta: table?)
---@param opts {limit: integer?, max_pages: integer?, cache_ttl: number?}?
function M.paginate(path, query, cb, opts)
  opts = opts or {}
  local per_page = opts.limit or config.options.request.per_page
  local max_pages = opts.max_pages or config.options.request.max_pages
  local acc = {}
  local page = 0

  local function fetch(offset)
    page = page + 1
    local page_query = vim.tbl_extend("force", query or {}, { limit = per_page, offset = offset })
    M.get(path, page_query, function(err, data, meta)
      if err then
        return cb(err)
      end
      if type(data) ~= "table" then
        return cb(nil, acc, meta)
      end
      -- Some Tuleap collections answer `{collection = [...]}` instead of a
      -- bare array (milestone content and backlog do this on older versions).
      local items = vim.islist(data) and data or (data.collection or data.items or {})
      vim.list_extend(acc, items)

      local total = meta and meta.total
      local done = #items < per_page
        or (total and #acc >= total)
        or page >= max_pages
      if done then
        return cb(nil, acc, meta)
      end
      fetch(offset + per_page)
    end, { cache_ttl = opts.cache_ttl })
  end

  fetch(0)
end

--- Blocking variant used by :checkhealth, where async output is unreadable.
---@param path string
---@param timeout integer?
---@return string? err, any? data
function M.get_sync(path, timeout)
  local done, result = false, {}
  M.get(path, nil, function(err, data)
    result = { err = err, data = data }
    done = true
  end, { cache_ttl = 0 })
  local ok = vim.wait(timeout or config.options.request.timeout, function()
    return done
  end, 50)
  if not ok then
    return "request timed out"
  end
  return result.err, result.data
end

return M
