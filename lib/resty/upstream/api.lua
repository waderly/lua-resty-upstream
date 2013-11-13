local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local str_format = string.format
local tbl_len = table.getn

local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }

local default_pool = {
    up = true,
    method = 'round_robin',
    timeout = 2000, -- socket timeout
    priority = 0,
    -- Hosts in this pool must fail `max_fails` times in `failed_timeout` seconds to be marked down for `failed_timeout` seconds
    failed_timeout = 60,
    max_fails = 3,
    hosts = {}
}
local numerics = {'priority', 'timeout', 'failed_timeout', 'max_fails'}

local default_host = {
    host = '',
    port = 80,
    up = true,
    weight = 0,
    failcount = 0,
    lastfail = 0
}


function _M.new(_, upstream)

    local self = {
        upstream = upstream,
        dict = upstream.dict,
        getPools = upstream.getPools,
        savePools = upstream.savePools,
        sortPools = upstream.sortPools
    }
    return setmetatable(self, mt), configured
end

function _M.setMethod(self, poolid, method)
    local available_methods = self.upstream.available_methods

    if not available_methods[method] then
        return nil, 'Method not found'
    end

    local pools = self:getPools()
    if not pools[poolid] then
        return nil, 'Pool not found'
    end
    pools[poolid].method = method

    return self:savePools(pools)
end

local function validatePool(opts, pools)
    if pools[opts.id] then
        return nil, 'Pool exists'
    end

    for _,key in ipairs(numerics) do
        if opts[key] and type(opts[key]) ~= "number" then
            return nil, key.. " must be a number"
        end
    end
    if opts[method] and not available_methods[opts[method]] then
        return nil, 'Method not available'
    end
    return true
end

function _M.createPool(self, opts)
    local poolid = opts.id
    if not poolid then
        return nil, 'No ID set'
    end

    local pools = self:getPools()

    local ok, err = validatePool(opts, pools)
    if not ok then
        return ok, err
    end

    local pool = {}
    for k,v in pairs(default_pool) do
        local val = opts[k] or v
        -- Can't set 'up' or 'hosts' values here
        if k == 'up' or k == 'hosts' then
            val = v
        end
        pool[k] = val
    end
    pools[poolid] = pool

    local ok, err = self:savePools(pools)
    if not ok then
        return ok, err
    end
    ngx.log(ngx.DEBUG, 'Created pool '..poolid)
    return self:sortPools(pools)
end

function _M.setPriority(self, poolid, priority)
    if type(priority) ~= 'number' then
        return nil, 'Priority must be a number'
    end

    local pools = self:getPools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end

    pools[poolid].priority = priority

    local ok, err = self:savePools(pools)
    if not ok then
        return ok, err
    end
    return self:sortPools(pools)
end

function _M.setWeight(self, poolid, weight)

end

function _M.addHost(self, poolid, host)
    local pools = self:getPools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end
    local pool = pools[poolid]

    -- Validate host definition and set defaults
    local hostid = host['id']
    if not hostid or pool.hosts[hostid] ~= nil then
        hostid = tbl_len(pool.hosts)+1
    end

    local new_host = {}
    for key, default in pairs(default_host) do
        local val = host[key] or default
        new_host[key] = val
    end

    pool.hosts[hostid] = new_host

    return self:savePools(pools)
end

function _M.removeHost(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end

    pool.hosts[host] = nil

    return self:savePools(pools)
end

function _M.hostDown(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool '.. poolid ..' not found'
    end
    local host = pool.hosts[host]
    if not host then
        return nil, 'Host not found'
    end

    host.up = false
    host.manual = true
    ngx_log(ngx_debug, str_format('Host "%s" in Pool "%s" is manually down', host.id, poolid))

    return self:savePools(pools)
end

function _M.hostUp(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end
    local host = pool.hosts[host]
    if not host then
        return nil, 'Host not found'
    end

    host.up = true
    host.manual = nil
    ngx_log(ngx_debug, str_format('Host "%s" in Pool "%s" is manually up', host.id, poolid))

    return self:savePools(pools)
end

return _M