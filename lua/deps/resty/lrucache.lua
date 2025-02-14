-- Copyright (C) Yichun Zhang (agentzh)


local ffi = require "ffi"
local ffi_new = ffi.new
local ffi_sizeof = ffi.sizeof
local ffi_cast = ffi.cast
local ffi_fill = ffi.fill
local ngx_now = os.time()
local uintptr_t = ffi.typeof("uintptr_t")
local setmetatable = setmetatable
local tonumber = tonumber
local type = type
local new_tab
do
    local ok
    ok, new_tab = pcall(require, "table.new")
    if not ok then
        new_tab = function(narr, nrec) return {} end
    end
end


local ok, tb_clear = pcall(require, "table.clear")
if not ok then
    local pairs = pairs
    tb_clear = function (tab)
        for k, _ in pairs(tab) do
            tab[k] = nil
        end
    end
end


-- queue data types
--
-- this queue is a double-ended queue and the first node
-- is reserved for the queue itself.
-- the implementation is mostly borrowed from nginx's ngx_queue_t data
-- structure.

ffi.cdef[[
    typedef struct lrucache_queue_s  lrucache_queue_t;
    struct lrucache_queue_s {
        double             expire;  /* in seconds */
        lrucache_queue_t  *prev;
        lrucache_queue_t  *next;
        uint32_t           user_flags;
    };
]]

local queue_arr_type = ffi.typeof("lrucache_queue_t[?]")
local queue_type = ffi.typeof("lrucache_queue_t")
local NULL = ffi.null


-- queue utility functions

local function queue_insert_tail(h, x)
    local last = h[0].prev
    x.prev = last
    last.next = x
    x.next = h
    h[0].prev = x
end


local function queue_init(size)
    if not size then
        size = 0
    end
    local q = ffi_new(queue_arr_type, size + 1)
    ffi_fill(q, ffi_sizeof(queue_type, size + 1), 0)

    if size == 0 then
        q[0].prev = q
        q[0].next = q

    else
        local prev = q[0]
        for i = 1, size do
          local e = q + i
          e.user_flags = 0
          prev.next = e
          e.prev = prev
          prev = e
        end

        local last = q[size]
        last.next = q
        q[0].prev = last
    end

    return q
end


local function queue_is_empty(q)
    -- print("q: ", tostring(q), "q.prev: ", tostring(q), ": ", q == q.prev)
    return q == q[0].prev
end


local function queue_remove(x)
    local prev = x.prev
    local next = x.next

    next.prev = prev
    prev.next = next

    -- for debugging purpose only:
    x.prev = NULL
    x.next = NULL
end


local function queue_insert_head(h, x)
    x.next = h[0].next
    x.next.prev = x
    x.prev = h
    h[0].next = x
end


local function queue_last(h)
    return h[0].prev
end


local function queue_head(h)
    return h[0].next
end


-- true module stuffs

local _M = {
    _VERSION = '0.10'
}
local mt = { __index = _M }


local function ptr2num(ptr)
    return tonumber(ffi_cast(uintptr_t, ptr))
end


function _M.new(size)
    if size < 1 then
        return nil, "size too small"
    end

    local self = {
        hasht = {},
        free_queue = queue_init(size),
        cache_queue = queue_init(),
        key2node = {},
        node2key = {},
        num_items = 0,
        max_items = size,
    }
    return setmetatable(self, mt)
end


function _M.count(self)
    return self.num_items
end


function _M.capacity(self)
    return self.max_items
end


function _M.get(self, key)
    local hasht = self.hasht
    local val = hasht[key]
    if val == nil then
        return nil
    end

    local node = self.key2node[key]

    -- print(key, ": moving node ", tostring(node), " to cache queue head")
    local cache_queue = self.cache_queue
    queue_remove(node)
    queue_insert_head(cache_queue, node)

    if node.expire >= 0 and node.expire < ngx_now then
        -- print("expired: ", node.expire, " > ", ngx_now())
        return nil, val, node.user_flags
    end

    return val, nil, node.user_flags
end


function _M.delete(self, key)
    self.hasht[key] = nil

    local key2node = self.key2node
    local node = key2node[key]

    if not node then
        return false
    end

    key2node[key] = nil
    self.node2key[ptr2num(node)] = nil

    queue_remove(node)
    queue_insert_tail(self.free_queue, node)
    self.num_items = self.num_items - 1
    return true
end


function _M.set(self, key, value, ttl, flags)
    local hasht = self.hasht
    hasht[key] = value

    local key2node = self.key2node
    local node = key2node[key]
    if not node then
        local free_queue = self.free_queue
        local node2key = self.node2key

        if queue_is_empty(free_queue) then
            -- evict the least recently used key
            -- assert(not queue_is_empty(self.cache_queue))
            node = queue_last(self.cache_queue)

            local oldkey = node2key[ptr2num(node)]
            -- print(key, ": evicting oldkey: ", oldkey, ", oldnode: ",
            --         tostring(node))
            if oldkey then
                hasht[oldkey] = nil
                key2node[oldkey] = nil
            end

        else
            -- take a free queue node
            node = queue_head(free_queue)
            -- only add count if we are not evicting
            self.num_items = self.num_items + 1
            -- print(key, ": get a new free node: ", tostring(node))
        end

        node2key[ptr2num(node)] = key
        key2node[key] = node
    end

    queue_remove(node)
    queue_insert_head(self.cache_queue, node)

    if ttl then
        node.expire = ngx_now + ttl
    else
        node.expire = -1
    end

    if type(flags) == "number" and flags >= 0 then
        node.user_flags = flags

    else
        node.user_flags = 0
    end
end


function _M.get_keys(self, max_count, res)
    if not max_count or max_count == 0 then
        max_count = self.num_items
    end

    if not res then
        res = new_tab(max_count + 1, 0) -- + 1 for trailing hole
    end

    local cache_queue = self.cache_queue
    local node2key = self.node2key

    local i = 0
    local node = queue_head(cache_queue)

    while node ~= cache_queue do
        if i >= max_count then
            break
        end

        i = i + 1
        res[i] = node2key[ptr2num(node)]
        node = node.next
    end

    res[i + 1] = nil

    return res
end


function _M.flush_all(self)
    tb_clear(self.hasht)
    tb_clear(self.node2key)
    tb_clear(self.key2node)

    self.num_items = 0

    local cache_queue = self.cache_queue
    local free_queue = self.free_queue

    -- splice the cache_queue into free_queue
    if not queue_is_empty(cache_queue) then
        local free_head = free_queue[0]
        local free_last = free_head.prev

        local cache_head = cache_queue[0]
        local cache_first = cache_head.next
        local cache_last = cache_head.prev

        free_last.next = cache_first
        cache_first.prev = free_last

        cache_last.next = free_head
        free_head.prev = cache_last

        cache_head.next = cache_queue
        cache_head.prev = cache_queue
    end
end


return _M
