---@mod tuleap.api.users Users

local client = require("tuleap.api.client")

local M = {}

---@type table?
local me = nil

--- The authenticated user. Cached for the whole session.
---@param cb fun(err: string?, user: table?)
function M.self(cb)
  if me then
    return cb(nil, me)
  end
  client.get("/users/self", nil, function(err, user)
    if err then
      return cb(err)
    end
    me = user
    cb(nil, user)
  end, { cache_ttl = 3600 })
end

---@param id integer
---@param cb fun(err: string?, user: table?)
function M.get(id, cb)
  client.get(("/users/%d"):format(id), nil, cb, { cache_ttl = 3600 })
end

---@param query string username fragment
---@param cb fun(err: string?, users: table[]?)
function M.search(query, cb)
  client.get("/users", { query = query, limit = 50 }, cb, { cache_ttl = 60 })
end

--- Display name with a fallback chain, Tuleap is inconsistent here.
---@param user table?
---@return string
function M.label(user)
  if type(user) ~= "table" then
    return "—"
  end
  return user.display_name or user.real_name or user.username or ("#" .. tostring(user.id))
end

return M
