Rumble = Rumble or {}
Rumble.android_active_until = Rumble.android_active_until or 0

-- this entire engine is VERY poorly tested, and probably sucks a lot.

local function vibrate(duration)
    if duration <= 0 or not love.system or type(love.system.vibrate) ~= "function" then
        return false
    end
    local ok = pcall(love.system.vibrate, duration)
    return ok
end

local function duration_for(event, master)
    local base = Rumble.cat_duration(event.cat)
    -- android has NO amplitude api. "stronger" is faked by holding the buzz
    -- longer. power=0 maps to 25% of the base duration (never fully silent),
    -- power=100 maps to 100%, so a weak event still tickles rather than
    -- becoming definitionally invisible. the count factor is capped at 4 so a
    -- dozen coins in one frame can't become a solid ten-second drone.
    -- (android haptics are a joke. we do what we can.)
    local count = math.min(event.count or 1, 4)
    local power = Rumble.cat_power(event.cat)
    return math.max(0.012, base * (0.25 + 0.75 * power) * master * count)
end

function Rumble.run_android(dt, fired, master)
    local best, best_score = nil, 0
    for _, event in ipairs(fired) do
        if Rumble.cat_enabled(event.cat) then
            local score = Rumble.cat_power(event.cat) * math.min(event.count or 1, 4)
            if score > best_score then best, best_score = event, score end
        end
    end
    if not best then return end

    local now = Rumble.frame_clock or 0
    local duration = duration_for(best, master)
    local remaining = math.max(0, (Rumble.android_active_until or 0) - now)
    if remaining > 0 and duration <= remaining then
        Rumble.dbg("android SUPPRESS %s", best.cat)
        return
    end
    if vibrate(duration) then
        Rumble.android_active_until = now + duration
        Rumble.dbg("android PULSE %s power=%.3f master=%.3f dur=%.3f",
            best.cat, Rumble.cat_power(best.cat), master, duration)
    end
end
