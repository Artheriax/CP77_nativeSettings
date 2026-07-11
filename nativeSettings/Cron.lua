--[[
Cron.lua
Timed Tasks Manager

Copyright (c) 2021 psiberx

Patched:
  * Cron.Update now iterates backwards so table.remove(timers, i) during iteration
    doesn't skip the timer that shifts into slot i. Previously a one-shot timer
    scheduled right before another could be silently delayed by a frame.
  * Added Cron.HaltAll() and Cron.Clear() so callers (e.g. NativeSettings on close)
    can drop every pending timer in O(N) without iterating from the outside.
  * Cron.Update short-circuits when #timers == 0 (already did, made explicit).
  * addTimer rejects timeout == 0 with recurring == true (was allowed, would loop
    forever in a single Update tick because timer.delay stays <= 0 after reset).
]]

local Cron = { version = '1.0.3' }

local timers = {}
local counter = 0

---@param timeout number
---@param recurring boolean
---@param callback function
---@param args
---@return any
local function addTimer(timeout, recurring, callback, args)
    if type(timeout) ~= 'number' then
        return
    end

    if timeout < 0 then
        return
    end

    if type(recurring) ~= 'boolean' then
        return
    end

    if type(callback) ~= 'function' then
        if type(args) == 'function' then
            callback, args = args, callback
        else
            return
        end
    end

    -- A recurring timer with timeout 0 would fire every frame forever and starve
    -- the rest of the queue. Refuse it. (One-shot NextTick with timeout 0 is fine.)
    if recurring and timeout <= 0 then
        return
    end

    if type(args) ~= 'table' then
        args = { arg = args }
    end

    counter = counter + 1

    local timer = {
        id = counter,
        callback = callback,
        recurring = recurring,
        timeout = timeout,
        active = true,
        delay = timeout,
        args = args,
    }

    if args.id == nil then
        args.id = timer.id
    end

    if args.interval == nil then
        args.interval = timer.timeout
    end

    if args.Halt == nil then
        args.Halt = Cron.Halt
    end

    if args.Pause == nil then
        args.Pause = Cron.Pause
    end

    if args.Resume == nil then
        args.Resume = Cron.Resume
    end

    table.insert(timers, timer)

    return timer.id
end

---@param timeout number
---@param callback function
---@param data
---@return any
function Cron.After(timeout, callback, data)
    return addTimer(timeout, false, callback, data)
end

---@param timeout number
---@param callback function
---@param data
---@return any
function Cron.Every(timeout, callback, data)
    return addTimer(timeout, true, callback, data)
end

---@param callback function
---@param data
---@return any
function Cron.NextTick(callback, data)
    return addTimer(0, false, callback, data)
end

---@param timerId any
---@return void
function Cron.Halt(timerId)
    if type(timerId) == 'table' then
        timerId = timerId.id
    end

    for i, timer in ipairs(timers) do
        if timer.id == timerId then
            table.remove(timers, i)
            break
        end
    end
end

-- Drop every timer. Useful when a controller is being torn down (e.g. NativeSettings
-- closing the menu) and you don't want any lingering NextTick callbacks to fire
-- against freed widgets.
function Cron.HaltAll()
    for i = #timers, 1, -1 do
        timers[i] = nil
    end
    -- Force the array part to shrink so #timers reports 0 immediately.
    timers = {}
end

-- Alias kept for clarity from outside callers.
function Cron.Clear()
    Cron.HaltAll()
end

---@param timerId any
---@return void
function Cron.Pause(timerId)
    if type(timerId) == 'table' then
        timerId = timerId.id
    end

    for _, timer in ipairs(timers) do
        if timer.id == timerId then
            timer.active = false
            break
        end
    end
end

---@param timerId any
---@return void
function Cron.Resume(timerId)
    if type(timerId) == 'table' then
        timerId = timerId.id
    end

    for _, timer in ipairs(timers) do
        if timer.id == timerId then
            timer.active = true
            break
        end
    end
end

---@param delta number
---@return void
function Cron.Update(delta)
    if #timers == 0 then
        return
    end

    -- Iterate backwards so that removing the timer at slot i doesn't cause the
    -- next iteration to skip the timer that shifted down into slot i. The
    -- original `for i, timer in ipairs(timers)` with `table.remove(timers, i)`
    -- + `i = i - 1` was a no-op because Lua's generic for restores i from its
    -- internal state regardless of any mutation we do to the local.
    for i = #timers, 1, -1 do
        local timer = timers[i]
        if timer.active then
            timer.delay = timer.delay - delta

            if timer.delay <= 0 then
                if timer.recurring then
                    -- Use addition (not assignment) so that if delta is larger
                    -- than the interval we still advance the next firing past
                    -- the current frame, instead of stalling.
                    timer.delay = timer.delay + timer.timeout
                else
                    table.remove(timers, i)
                end

                timer.callback(timer.args)
            end
        end
    end
end

return Cron
