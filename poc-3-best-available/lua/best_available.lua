-- best_available.lua — Find contiguous runs of available seats
-- KEYS[1] = seats:event:1           (HSET: seatId → status)
-- KEYS[2] = venue:event:1:rows      (HSET: "A-1" → comma-sep seatIds)
-- ARGV[1] = quantity requested
-- ARGV[2] = target section (or "*" for any)
-- ARGV[3] = focal row (center of venue, for proximity ranking)
-- ARGV[4] = focal index (center seat in focal row)

local seatsKey = KEYS[1]
local rowsKey = KEYS[2]
local quantity = tonumber(ARGV[1])
local targetSection = ARGV[2]
local focalRow = tonumber(ARGV[3]) or 0
local focalIndex = tonumber(ARGV[4]) or 0

-- Step 1: Get all rows filtered by section
local rows = redis.call('HGETALL', rowsKey)
local candidates = {}

for i = 1, #rows, 2 do
  local rowId = rows[i]
  local seatIds = rows[i + 1]

  -- Filter by section if specified
  if targetSection == '*' or string.find(rowId, targetSection) then
    -- Parse seat IDs and their positions
    local pos = 1
    local seatNum = 1
    local runStart = 0
    local runLen = 0
    local bestRun = nil
    local bestScore = math.huge

    for seatId in string.gmatch(seatIds, '([^,]+)') do
      local status = redis.call('HGET', seatsKey, seatId) or 'available'
      if status == 'available' then
        if runLen == 0 then runStart = seatNum end
        runLen = runLen + 1
      else
        if runLen >= quantity then
          -- Score by proximity to focal point
          local runCenter = runStart + math.floor(runLen / 2)
          local rowNum = tonumber(string.match(rowId, '%d+')) or 0
          local score = math.abs(rowNum - focalRow) * 1000 + math.abs(runCenter - focalIndex)
          if score < bestScore then
            bestScore = score
            bestRun = {row=rowId, start=runStart, length=runLen, seatId=seatId}
          end
        end
        runLen = 0
      end
      seatNum = seatNum + 1
    end

    -- Check final run in this row
    if runLen >= quantity then
      local runCenter = runStart + math.floor(runLen / 2)
      local rowNum = tonumber(string.match(rowId, '%d+')) or 0
      local score = math.abs(rowNum - focalRow) * 1000 + math.abs(runCenter - focalIndex)
      if score < bestScore then
        bestScore = score
        bestRun = {row=rowId, start=runStart, length=runLen, seatId=seatId}
      end
    end

    if bestRun then
      -- Return the seat IDs in the winning run
      local result = {}
      local rowSeats = {}
      for seatId in string.gmatch(seatIds, '([^,]+)') do
        table.insert(rowSeats, seatId)
      end
      for j = bestRun.start, bestRun.start + quantity - 1 do
        if rowSeats[j] then
          table.insert(result, rowSeats[j])
        end
      end
      return {1, table.concat(result, ',')}
    end
  end
end

return {0, 'no_contiguous_block'}
