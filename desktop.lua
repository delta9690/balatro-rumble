-- desktop.lua - the gamepad rumble engine. attack -> hold -> decay envelope,
-- split across two motor channels with constant-power panning.
-- gate the heavy motor channel, reroute sub-stall energy to the light motor that can actually
-- render it, and arbitrate by intrinsic importance instead of raw volume.


Rumble = Rumble or {}

Rumble.desktop_env = Rumble.desktop_env or {
    level = 0,
    peak = 0,
    light_hold = 0,
    heavy_hold = 0,
    decay = 10,
    heavy = 0.5,
    heavy_filter_notice_at = -999,

    -- latched once per burst at attack. decides for the WHOLE burst whether
    -- the heavy motor participates at all. testing this per-frame is what
    -- made the light motor double mid-tail: as the envelope decayed through
    -- the stall floor, the pan angle snapped from 0.5 to 0 in one frame.
    heavy_active = true,
}

Rumble.desktop_env.light_hold = tonumber(Rumble.desktop_env.light_hold) or tonumber(Rumble.desktop_env.hold) or 0
Rumble.desktop_env.heavy_hold = tonumber(Rumble.desktop_env.heavy_hold) or 0
Rumble.desktop_env.heavy_filter_notice_at = tonumber(Rumble.desktop_env.heavy_filter_notice_at) or -999

Rumble.last_fire = Rumble.last_fire or {}

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

-- device dependent, hence configurable. below this the heavy motor just
-- stalls rather than buzzing weakly, so there is no point commanding it.
local function heavy_floor()
    local v = tonumber(Rumble.MOD.config.heavy_stall_floor) or 15
    return math.max(0, math.min(100, v)) / 100
end

local function heavy_gate_on()
    local v = Rumble.MOD.config.heavy_gate
    if v == nil then
        return true
    end
    return v ~= false
end

-- decides, from a burst's PEAK command, whether the heavy motor is worth
-- driving at all this burst. pure function of (mix, peak, master) so the
-- answer can be computed once at attack and then trusted for the whole tail.
local function heavy_participates(heavy, peak, master)
    if not heavy_gate_on() or heavy <= 0 then
        return true
    end

    local peak_amt = clamp01((peak or 0) * (master or 1))
    local peak_left = peak_amt * math.sin(heavy * math.pi / 2)

    return peak_left >= heavy_floor()
end

local function heavy_has_time(cat)
    local hold_s = Rumble.hold_heavy_s()
    local min_s = Rumble.heavy_min_impulse_s()

    if hold_s >= min_s then
        return true
    end

    local now = Rumble.frame_clock or 0
    local env = Rumble.desktop_env
    if now - (env.heavy_filter_notice_at or -999) >= 1.5 then
        env.heavy_filter_notice_at = now
        sendDebugMessage(string.format(
            "Rumble: rerouted %s to light motor (heavy hold %.0fms < min impulse %.0fms).",
            cat, hold_s * 1000, min_s * 1000
        ))
    end

    return false
end

local function heavy_usable(cat, heavy, peak, master)
    if heavy <= 0 then
        return false
    end

    if not heavy_gate_on() then
        return true
    end

    return heavy_participates(heavy, peak, master) and heavy_has_time(cat)
end

local function apply_rumble(left, right)
    local controller = G and G.CONTROLLER
    local gamepad = controller and controller.GAMEPAD
    local pad = gamepad and gamepad.object

    if not pad then
        return
    end

    pcall(function()
        if type(pad.isConnected) == "function" and not pad:isConnected() then
            return
        end
        pad:setVibration(left, right)
    end)
end

-- strongest-wins, but ranked by INTRINSIC weight first and tuned volume
-- second. otherwise cranking a menu tap's strength makes it outrank the
-- round's cash out, which is exactly what the log showed happening twice.
local function pick_winner(eligible)
    local cat, w, rank = nil, 0, -1

    for _, ev in ipairs(eligible) do
        if Rumble.cat_enabled(ev.cat) then
            local meta = Rumble.CATEGORY_DEFAULTS[ev.cat]
            local tuned = (ev.force_weight or meta.base_weight)
                * (Rumble.cat_strength(ev.cat) / 100)

            local importance = meta.base_weight

            if tuned > 0 and (importance > rank or (importance == rank and tuned > w)) then
                cat, w, rank = ev.cat, tuned, importance
            end
        end
    end

    return cat, w
end

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

    local strongest_cat, strongest = pick_winner(eligible)
    local before = env.level

    if strongest_cat and strongest > 0 then
        Rumble.last_fire[strongest_cat] = Rumble.frame_clock

        if env.level <= 0 then
            env.level = math.min(1, strongest)
            env.peak = env.level
            env.decay = math.max(1, Rumble.cat_decay(strongest_cat))
            env.heavy = Rumble.cat_heavy_frac(strongest_cat)
            env.heavy_active = heavy_usable(strongest_cat, env.heavy, env.peak, master)
            env.light_hold = Rumble.hold_light_s()
            env.heavy_hold = env.heavy_active and Rumble.hold_heavy_s() or 0
            Rumble.dbg("desktop ATTACK %s w=%.3f heavy=%.2f (level %.3f->%.3f)",
                strongest_cat, strongest, env.heavy, before, env.level)
        elseif strongest > env.level then
            env.level = math.min(1, strongest)
            env.peak = env.level
            env.decay = math.max(1, Rumble.cat_decay(strongest_cat))
            env.heavy = Rumble.cat_heavy_frac(strongest_cat)
            env.heavy_active = heavy_usable(strongest_cat, env.heavy, env.peak, master)
            env.light_hold = Rumble.hold_light_s()
            env.heavy_hold = env.heavy_active and Rumble.hold_heavy_s() or 0
            Rumble.dbg("desktop ESCALATE %s w=%.3f heavy=%.2f (level %.3f->%.3f)",
                strongest_cat, strongest, env.heavy, before, env.level)
        else
            env.level = math.max(env.level, math.min(1, strongest))
            env.light_hold = math.max(env.light_hold or 0, Rumble.hold_light_s() * 0.25)
            if env.heavy_active then
                env.heavy_hold = math.max(env.heavy_hold or 0, Rumble.hold_heavy_s() * 0.25)
            end
            Rumble.dbg("desktop BLEND %s w=%.3f (level %.3f)",
                strongest_cat, strongest, env.level)
        end
    end

    if env.level > 0 then
        if env.light_hold > 0 then
            env.light_hold = env.light_hold - dt
        end

        if env.heavy_hold > 0 then
            env.heavy_hold = env.heavy_hold - dt
        end

        if env.light_hold <= 0 and env.heavy_hold <= 0 then
            env.level = env.level * math.exp(-env.decay * dt)

            if env.level < 0.002 then
                env.level = 0
                env.peak = 0
                env.light_hold = 0
                env.heavy_hold = 0
                Rumble.dbg("desktop burst ended")
            end
        end
    end

    local amt = clamp01(env.level * master)

    -- one continuous pan, no per-frame branch. when the heavy motor doesn't
    -- participate, t = 0 routes the FULL amplitude to the light motor via
    -- cos(0) = 1. that's a straight fold, not an addition, so the light motor
    -- gets exactly `amt` and never doubles. it also means there's no mid-burst
    -- discontinuity left to hear, because the decision was made at attack.
    local t = 0
    if env.heavy_active then
        t = env.heavy or 0.5
    end

    local left = clamp01(amt * math.sin(t * math.pi / 2))
    local right = clamp01(amt * math.cos(t * math.pi / 2))

    if Rumble.verbose() then
        Rumble.dbg("desktop COMMAND L=%.3f R=%.3f t=%.2f", left, right, t)
    end

    apply_rumble(left, right)
end