-- best_available.lua — Find contiguous runs of available seats (global best + orphan check)
-- KEYS[1] = seats:event:1           (HSET: seatId -> status)
-- KEYS[2] = venue:event:1:rows      (HSET: "A-1" -> comma-sep seatIds)
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
  local seatIdsStr = rows[i + 1]

  -- Filter by section if specified
  if targetSection == '*' or string.find(rowId, targetSection) then
    -- Parse all seat IDs into an array
    local rowSeats = {}
    for seatId in string.gmatch(seatIdsStr, '([^,]+)') do
      table.insert(rowSeats, seatId)
    end
    local totalInRow = #rowSeats

    -- Build availability bitmap for this row
    local avail = {}
    for idx = 1, totalInRow do
      local status = redis.call('HGET', seatsKey, rowSeats[idx])
      if status == false or status == 'available' then
        avail[idx] = true
      else
        avail[idx] = false
      end
    end

    -- Find contiguous runs of available seats
    local runStart = 0
    local runLen = 0

    for idx = 1, totalInRow do
      if avail[idx] then
        if runLen == 0 then runStart = idx end
        runLen = runLen + 1
      else
        -- End of run, evaluate it
        if runLen >= quantity then
          -- Try all valid sub-runs of exactly `quantity` within this run
          for offset = 0, runLen - quantity do
            local selStart = runStart + offset
            local selEnd = selStart + quantity - 1

            -- Orphan check: would selecting this run leave a single isolated seat?
            local leftOrphan = false
            local rightOrphan = false

            -- Left orphan: if there's exactly 1 available seat to the left of our selection
            -- that would become isolated (seat at selStart-1 is available, selStart-2 is not or boundary)
            if selStart > 1 and avail[selStart - 1] then
              -- Check if seat at selStart-1 would be isolated (no available neighbor on its left)
              if selStart - 1 == 1 or not avail[selStart - 2] then
                leftOrphan = true
              end
            end

            -- Right orphan: if there's exactly 1 available seat to the right of our selection
            -- that would become isolated
            if selEnd < totalInRow and avail[selEnd + 1] then
              if selEnd + 1 == totalInRow or not avail[selEnd + 2] then
                rightOrphan = true
              end
            end

            if not leftOrphan and not rightOrphan then
              -- Score by proximity to focal point
              local runCenter = selStart + math.floor(quantity / 2)
              local rowNum = tonumber(string.match(rowId, '%d+')) or 0
              local score = math.abs(rowNum - focalRow) * 1000 + math.abs(runCenter - focalIndex)

              table.insert(candidates, {
                row = rowId,
                start = selStart,
                score = score
              })
              -- Only keep the best offset per run to limit candidates
              break
            end
          end
        end
        runLen = 0
      end
    end

    -- Check final run at end of row
    if runLen >= quantity then
      for offset = 0, runLen - quantity do
        local selStart = runStart + offset
        local selEnd = selStart + quantity - 1

        local leftOrphan = false
        local rightOrphan = false

        if selStart > 1 and avail[selStart - 1] then
          if selStart - 1 == 1 or not avail[selStart - 2] then
            leftOrphan = true
          end
        end

        if selEnd < totalInRow and avail[selEnd + 1] then
          if selEnd + 1 == totalInRow or not avail[selEnd + 2] then
            rightOrphan = true
          end
        end

        if not leftOrphan and not rightOrphan then
          local runCenter = selStart + math.floor(quantity / 2)
          local rowNum = tonumber(string.match(rowId, '%d+')) or 0
          local score = math.abs(rowNum - focalRow) * 1000 + math.abs(runCenter - focalIndex)

          table.insert(candidates, {
            row = rowId,
            start = selStart,
            score = score
          })
          break
        end
      end
    end
  end
end

-- Step 2: No candidates found
if #candidates == 0 then
  return cjson.encode({status = 0, error = 'no_contiguous_block'})
end

-- Step 3: Sort candidates by score (lowest = closest to focal point) and pick the best
table.sort(candidates, function(a, b) return a.score < b.score end)
local best = candidates[1]

-- Step 4: Collect seat IDs for the winning run
local winRowSeats = {}
local winRowData = redis.call('HGET', rowsKey, best.row)
for seatId in string.gmatch(winRowData, '([^,]+)') do
  table.insert(winRowSeats, seatId)
end

local result = {}
for j = best.start, best.start + quantity - 1 do
  if winRowSeats[j] then
    -- Mark as held atomically
    redis.call('HSET', seatsKey, winRowSeats[j], 'held:best-available')
    table.insert(result, winRowSeats[j])
  end
end

return cjson.encode({status = 1, seats = result, row = best.row})
