-- hold_bitfield.lua — BITFIELD approach: 2 bits per seat
-- KEYS[1] = seats:event:1:bits
-- KEYS[2] = seats:event:1:holders
-- ARGV[1] = seat index (0-based integer)
-- ARGV[2] = holderId
local bitsKey = KEYS[1]
local holdersKey = KEYS[2]
local offset = tonumber(ARGV[1]) * 2  -- 2 bits per seat
local holderId = ARGV[2]

-- Read current 2-bit status: 0=available, 1=held, 2=booked, 3=reserved
local current = redis.call('BITFIELD', bitsKey, 'GET', 'u2', offset)
if current[1] ~= 0 then
  return {0, 'seat_unavailable'}
end

-- Set to held (1)
redis.call('BITFIELD', bitsKey, 'SET', 'u2', offset, 1)
-- Store holder mapping
redis.call('HSET', holdersKey, ARGV[1], holderId)
return {1, 'ok'}
