-- desktop.lua - the gamepad rumble engine. attack -> hold -> decay envelope,
-- split across two motor channels with constant-power panning.
--
-- the old linear split (left = amt*heavy, right = amt*(1-heavy)) halved both
-- motors at a balanced mix. a 50/50 mix became 0.5 and 0.5 instead of
-- something strong. sin/cos crossfade fixes that - balanced runs both motors
-- at ~0.707 of commanded amplitude, so total perceived power stays flat
-- across the whole heavy/light range.

Rumble = Rumble or {}

Rumble.desktop_env = Rumble.desktop_env or {
    level = 0,
    peak = 0,
    hold = 0,
    decay = 10,
    heavy = 0.5,
}

Rumble.last_fire = Rumble.last_fire or {}

--------------------------------------------------
------------------ HELPERS ------------------------
--------------------------------------------------

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

-- the pad can be unplugged at any moment, and a stale joystick userdata is
-- not something to gamble on across every sdl/xinput combination. check
-- connection and swallow any error instead of taking down the frame.
local function apply_rumble(left, right)
    local controller = G and G.CONTROLLER
    local gamepad = controller and controller.GAMEPAD
    local pad = gamepad and gamepad.object

    if not pad then
        return
    end

    pcall(function()
        if type(pad.isConnected) == "function" then
            if not pad:isConnected() then
                return
            end
        end

        pad:setVibration(left, right)
    end)
end

--------------------------------------------------
------------------ DESKTOP ENGINE -----------------
--------------------------------------------------

function Rumble.run_desktop(dt, fired, master)
    local env = Rumble.desktop_env

    -- drop same-category events landing too soon after the previous tick.
    -- fast d-pad spam was turning into one long mushy hum instead of ticks.
    local eligible = {}
    for _, ev in ipairs(fired) do
        local since = (Rumble.frame_clock or 0) - (Rumble.last_fire[ev.cat] or -999)
        local gap = Rumble.cat_min_retrigger(ev.cat)

        if since >= gap then
            eligible[#eligible + 1] = ev
        else
            Rumble.dbg("desktop SUPPRESS %s (%.3fs < %.3fs)", ev.cat, since, gap)
        end
    end

    -- strongest eligible event owns the frame. counts do NOT multiply desktop
    -- amplitude; that was the bug where four stacked coins felt like a cash
    -- out. count only matters on android, where it lengthens the pulse.
    local strongest, strongest_cat = 0, nil
    for _, ev in ipairs(eligible) do
        if Rumble.cat_enabled(ev.cat) then
            local w = (ev.force_weight or Rumble.CATEGORY_DEFAULTS[ev.cat].base_weight)
                * (Rumble.cat_strength(ev.cat) / 100)

            if w > strongest then
                strongest, strongest_cat = w, ev.cat
            end
        end
    end

    local before = env.level

    if strongest > 0 then
        Rumble.last_fire[strongest_cat] = Rumble.frame_clock

        if env.level <= 0 then
            env.level = math.min(1, strongest)
            env.peak = env.level
            env.decay = math.max(1, Rumble.cat_decay(strongest_cat))
            env.heavy = Rumble.cat_heavy_frac(strongest_cat)
            env.hold = Rumble.hold_s()
            Rumble.dbg("desktop ATTACK %s w=%.3f heavy=%.2f (level %.3f->%.3f)",
                strongest_cat, strongest, env.heavy, before, env.level)
        elseif strongest > env.level then
            env.level = math.min(1, strongest)
            env.peak = env.level
            env.decay = math.max(1, Rumble.cat_decay(strongest_cat))
            env.heavy = Rumble.cat_heavy_frac(strongest_cat)
            env.hold = Rumble.hold_s()
            Rumble.dbg("desktop ESCALATE %s w=%.3f heavy=%.2f (level %.3f->%.3f)",
                strongest_cat, strongest, env.heavy, before, env.level)
        else
            env.level = math.max(env.level, math.min(1, strongest))
            env.hold = math.max(env.hold, Rumble.hold_s() * 0.25)
            Rumble.dbg("desktop BLEND %s w=%.3f (level %.3f)",
                strongest_cat, strongest, env.level)
        end
    end

    if env.level > 0 then
        if env.hold > 0 then
            env.hold = env.hold - dt
        else
            env.level = env.level * math.exp(-env.decay * dt)

            if env.level < 0.002 then
                env.level = 0
                env.peak = 0
                Rumble.dbg("desktop burst ended")
            end
        end
    end

    local amt = clamp01(env.level * 0.4 * master)

    -- constant-power crossfade. single-motor pads end up using max(left,
    -- right), so a balanced mix still feeds one motor ~0.707 instead of the
    -- old 0.5, which is strictly an improvement there too.
    local t = env.heavy or 0.5
    local left = clamp01(amt * math.sin(t * math.pi / 2))
    local right = clamp01(amt * math.cos(t * math.pi / 2))

    apply_rumble(left, right)
end