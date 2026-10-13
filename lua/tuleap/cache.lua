---@mod tuleap.cache Tiny TTL cache for REST responses
---
--- Tuleap tracker schemas and project lists are expensive to fetch and change
--- rarely, so they are memoised. Anything that writes to the API calls
--- |tuleap.cache.invalidate| with a prefix to drop the stale entries.

local M = {}

---@type table<string, {value: any, expires: number}>
local store = {}

---@return number
local function now()
  return vim.uv.now() / 1000
end

---@param parts any[]
---@return string
function M.key(parts)
  local out = {}
  for _, part in ipairs(parts) do
    out[#out + 1] = type(part) == "table" and vim.json.encode(part) or tostring(part)
  end
  return table.concat(out, ":")
end

---@param key string
---@return any?
function M.get(key)
  local config = require("tuleap.config")
  if not config.options.cache.enabled then
    return nil
  end
  local entry = store[key]
  if not entry then
    return nil
  end
  if entry.expires < now() then
    store[key] = nil
    return nil
  end
  return entry.value
end

---@param key string
---@param value any
---@param ttl number? seconds, defaults to `cache.ttl`
function M.set(key, value, ttl)
  local config = require("tuleap.config")
  if not config.options.cache.enabled then
    return value
  end
  store[key] = { value = value, expires = now() + (ttl or config.options.cache.ttl) }
  return value
end

--- Drop every entry whose key starts with `prefix` (or the whole cache).
---@param prefix string?
function M.invalidate(prefix)
  if not prefix then
    store = {}
    return
  end
  for key in pairs(store) do
    if key:sub(1, #prefix) == prefix then
      store[key] = nil
    end
  end
end

---@return integer
function M.size()
  return vim.tbl_count(store)
end

return M
