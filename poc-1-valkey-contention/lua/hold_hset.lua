-- hold_hset.lua — Current approach: one hash field per seat
-- KEYS[1] = seats:event:1
-- ARGV[1] = seatId (e.g. "seat:00001")
-- ARGV[2] = holdToken
-- ARGV[3] = ttl (seconds)
-- ARGV[4] = now (unix timestamp)
local key = KEYS[1]
local seatId = ARGV[1]
local holdToken = ARGV[2]
local ttl = tonumber(ARGV[3])
local now = tonumber(ARGV[4])

local current = redis.call('HGET', key, seatId)
if current and current ~= '' then
  local status = string.match(current, '^([^:]+)')
  if status ~= 'available' then
    return {0, 'seat_unavailable'}
  end
end

local val = 'held:' .. holdToken .. '::' .. (now + ttl)
redis.call('HSET', key, seatId, val)
return {1, 'ok'}
