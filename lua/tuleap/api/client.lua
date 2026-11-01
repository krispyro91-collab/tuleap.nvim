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

--- Per-route cap on the `limit` query parameter.
---
--- Tuleap declares a different maximum per REST route (50 on `/projects`, 100
--- on most collections) and answers HTTP 400 when it is exceeded. Caps are
--- learnt from the `X-PAGINATION-LIMIT-MAX` response header and from the error
--- message itself, then reused for the rest of the session.
---@type table<string, integer>
local limit_caps = {
  -- Seeded with the one route that is lower than our default `per_page`, so
  -- the very first `:Tuleap projects` does not have to fail to find out.
  ["/projects"] = 50,
}

--- Cap keys ignore ids: `/projects/101/trackers` and `/projects/102/trackers`
--- share the same limit.
---@param path string
---@return string
local function cap_key(path)
  return (path:gsub("%d+", "#"))
end

---@param path string
---@param wanted integer
---@return integer
local function capped_limit(path, wanted)
  local cap = limit_caps[cap_key(path)]
  return cap and math.min(wanted, cap) or wanted
end

---@param path string
---@param cap integer
local function remember_cap(path, cap)
  local key = cap_key(path)
  if not limit_caps[key] or cap < limit_caps[key] then
    limit_caps[key] = cap
    log.dev("limit cap for %s is now %d", key, cap)
  end
end

--- Extract the maximum Tuleap accepts out of its own error message, e.g.
--- "Invalid value specified for `limit`. Maximum allowed value is 50."
---@param err string
---@return integer?
local function cap_from_error(err)
  return tonumber(err:match("[Mm]aximum allowed value is (%d+)"))
end

--- Known cap for a route, exposed for tests and for callers building their own
--- paginated requests.
---@param path string
---@return integer?
function M.limit_cap(path)
  return limit_caps[cap_key(path)]
end

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

local perform

--- Perform a single request, once the access key is known.
---@param opts tuleap.RequestOpts
---@param cb fun(err: string?, data: any?, meta: table?)
function M.request(opts, cb)
  config.ensure_token(function()
    perform(opts, cb)
  end)
end

---@param opts tuleap.RequestOpts
---@param cb fun(err: string?, data: any?, meta: table?)
perform = function(opts, cb)
  cb = cb or function() end
  local ok, err = config.validate()
  if not ok then
    return vim.schedule(function()
      cb(err)
    end)
  end

  local method = (opts.method or "GET"):upper()

  -- Keep `limit` under the route's known cap: Tuleap rejects the whole request
  -- rather than clamping it itself.
  local wanted_limit = tonumber(opts.query and opts.query.limit)
  if wanted_limit then
    local allowed = capped_limit(opts.path, wanted_limit)
    if allowed ~= wanted_limit then
      opts.query = vim.tbl_extend("force", opts.query, { limit = allowed })
    end
  end

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
        if meta.limit_max then
          remember_cap(opts.path, meta.limit_max)
        end
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
---@param body table
---@param cb fun(err: string?, data: any?, meta: table?)
function M.patch(path, body, cb)
  M.request({ path = path, body = body, method = "PATCH" }, cb)
end

---@param path string
---@param cb fun(err: string?, data: any?, meta: table?)
function M.delete(path, cb)
  M.request({ path = path, method = "DELETE" }, cb)
end

--- Pages requested at once once a collection's size is known.
M.PAGE_CONCURRENCY = 4

--- Items of a collection page. Some Tuleap collections answer
--- `{collection = [...]}` instead of a bare array (milestone content and
--- backlog do this on older versions).
---@param data any
---@return any[]
local function page_items(data)
  if type(data) ~= "table" then
    return {}
  end
  return vim.islist(data) and data or (data.collection or data.items or {})
end

---@class tuleap.PaginateOpts
---@field limit integer?
---@field max_pages integer?
---@field cache_ttl number?
---@field on_page fun(items: any[])? called with every item received so far,
---       in collection order, each time a page arrives

--- Walk a paginated collection until it is exhausted (or `max_pages` is hit)
--- and hand the concatenated list to the callback.
---
--- The first page is read alone: it is where an oversized `limit` is caught,
--- and it carries the collection size. When that size is known, the remaining
--- pages are requested a few at a time instead of one after the other.
---@param path string
---@param query table?
---@param cb fun(err: string?, items: any[]?, meta: table?)
---@param opts tuleap.PaginateOpts?
function M.paginate(path, query, cb, opts)
  opts = opts or {}
  local per_page = capped_limit(path, opts.limit or config.options.request.per_page)
  local max_pages = opts.max_pages or config.options.request.max_pages

  ---@type any[][] pages received, by index; a gap is a page still in flight
  local pages = {}
  local finished = false

  ---@return any[]
  local function joined()
    local acc = {}
    local index = 1
    while pages[index] do
      vim.list_extend(acc, pages[index])
      index = index + 1
    end
    return acc
  end

  local function finish(err, meta)
    if finished then
      return
    end
    finished = true
    if err then
      return cb(err)
    end
    cb(nil, joined(), meta)
  end

  local function page_arrived()
    if opts.on_page and not finished then
      opts.on_page(joined())
    end
  end

  ---@param offset integer
  ---@param on_done fun(err: string?, items: any[]?, meta: table?)
  local function get_page(offset, on_done)
    local page_query = vim.tbl_extend("force", query or {}, { limit = per_page, offset = offset })
    M.get(path, page_query, function(err, data, meta)
      on_done(err, err == nil and page_items(data) or nil, meta)
    end, { cache_ttl = opts.cache_ttl })
  end

  --- Unknown size: follow the pages one after the other.
  ---@param index integer
  ---@param offset integer
  local function sequential(index, offset)
    get_page(offset, function(err, items, meta)
      if err then
        return finish(err)
      end
      pages[index] = items
      page_arrived()
      if #items < per_page or index >= max_pages then
        return finish(nil, meta)
      end
      sequential(index + 1, offset + #items)
    end)
  end

  --- Known size: request pages 2..last, `PAGE_CONCURRENCY` at a time.
  ---@param start integer offset of page 2
  ---@param last integer index of the last page to read
  ---@param first_meta table?
  local function parallel(start, last, first_meta)
    local next_index, pending = 2, 0
    local function pump()
      while not finished and pending < M.PAGE_CONCURRENCY and next_index <= last do
        local index = next_index
        next_index = next_index + 1
        pending = pending + 1
        get_page(start + (index - 2) * per_page, function(err, items)
          pending = pending - 1
          if finished then
            return
          end
          if err then
            return finish(err)
          end
          pages[index] = items
          page_arrived()
          if pending == 0 and next_index > last then
            return finish(nil, first_meta)
          end
          pump()
        end)
      end
    end
    pump()
  end

  local function first()
    get_page(0, function(err, items, meta)
      if err then
        -- The route caps `limit` lower than we asked: learn it and replay the
        -- same page. `per_page` strictly decreases, so this cannot loop.
        local cap = cap_from_error(err)
        if cap and cap < per_page then
          remember_cap(path, cap)
          per_page = cap
          return first()
        end
        return finish(err)
      end

      -- A successful page may still shrink the window for the next ones.
      if meta and meta.limit_max and meta.limit_max < per_page then
        per_page = meta.limit_max
      end
      pages[1] = items
      page_arrived()

      local total = meta and meta.total
      if #items < per_page or max_pages <= 1 or (total and #items >= total) then
        return finish(nil, meta)
      end
      if not total then
        return sequential(2, #items)
      end
      local last = 1 + math.ceil((total - #items) / per_page)
      parallel(#items, math.min(max_pages, last), meta)
    end)
  end

  first()
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
