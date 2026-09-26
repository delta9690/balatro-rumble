-- android.lua - the phone haptic engine. love.system.vibrate takes seconds
-- and has no amplitude, so "stronger" is faked with longer pulses.
--
-- love's vibrate REPLACES any in-progress vibration rather than extending
-- it. that is the same failure class as the old desktop double-write: a new
-- call mid-buzz restarts the motor and reads as a stutter. so we track when
-- the physical buzz ends and refuse to restart it unless the new pulse would
-- outlast what's left. per-category cooldowns still handle the settle gap.

Rumble = Rumble or {}

Rumble.android_cooldowns = Rumble.android_cooldowns or {}
Rumble.android_active_until = Rumble.android_active_until or 0

--------------------------------------------------
------------------ HELPERS ------------------------
--------------------------------------------------

local function vibrate(duration)
    if duration <= 0 then
        return false
    end

    if not love.system or type(love.system.vibrate) ~= "function" then
        sendDebugMessage("Rumble: love.system.vibrate isn't available on this build")
        return false
    end

    local ok, err = pcall(love.system.vibrate, duration)

    if not ok then
        sendDebugMessage("Rumble: android vibrate failed: " .. tostring(err))
    end

    return ok
end

--------------------------------------------------
------------------ ANDROID ENGINE -----------------
--------------------------------------------------

local function duration_for(best, master)
    local strength = (Rumble.cat_strength(best.cat) / 100)

    if best.cat == "startup_card" then
        -- title card phases get explicit lengths. no amplitude here, so
        -- open = moderate, ramp = tick, close = the big one.
        local base
        if best.phase == "close" then
            base = Rumble.cat_duration("startup_card")
        elseif best.phase == "open" then
            base = 0.12
        else
            base = 0.03
        end
        return base * master * strength
    end

    local base = Rumble.cat_duration(best.cat)
    return base * master * strength * math.min(best.count or 1, 4)
end

function Rumble.run_android(dt, fired, master)
    for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
        Rumble.android_cooldowns[cat] =
            math.max(0, (Rumble.android_cooldowns[cat] or 0) - dt)
    end

    -- one motor, so the strongest eligible event wins the frame. queueing
    -- them is what caused the old train-of-pulses mess.
    local best, best_score = nil, -1

    for _, ev in ipairs(fired) do
        if Rumble.cat_enabled(ev.cat)
            and (Rumble.android_cooldowns[ev.cat] or 0) <= 0 then

            local score = (ev.force_weight or Rumble.CATEGORY_DEFAULTS[ev.cat].base_weight)
                * (Rumble.cat_strength(ev.cat) / 100)
                * math.min(ev.count or 1, 4)

            if score > best_score then
                best_score, best = score, ev
            end
        end
    end

    if not best then
        return
    end

    local duration = math.max(Rumble.min_pulse(), duration_for(best, master))

    local now = Rumble.frame_clock or 0
    local remaining = (Rumble.android_active_until or 0) - now

    -- something is already buzzing. only interrupt it if this pulse would
    -- outlast what's left, otherwise we'd be restarting the motor for no
    -- perceptual gain and producing a stutter.
    if remaining > 0 and duration <= remaining then
        Rumble.dbg("android SKIP %s (%.3fs left)", best.cat, remaining)
        return
    end

    Rumble.dbg("android PULSE %s dur=%.3f", best.cat, duration)

    if vibrate(duration) then
        Rumble.android_cooldowns[best.cat] = duration + Rumble.settle()
        Rumble.android_active_until = now + duration
    end
end