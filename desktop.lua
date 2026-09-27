-- desktop.lua - the gamepad rumble engine. attack -> hold -> decay envelope,
-- split across two motor channels with constant-power panning.
-- gate the heavy motor channel, reroute sub-stall energy to the light motor that can actually
-- render it, and arbitrate by intrinsic importance instead of raw volume.


Rumble = Rumble or {}

Rumble.desktop_env = Rumble.desktop_env or {
    level = 0,
    peak = 0,
    hold = 0,
    decay = 10,
    heavy = 0.5,

    -- latched once per burst at attack. decides for the WHOLE burst whether
    -- the heavy motor participates at all. testing this per-frame is what
    -- made the light motor double mid-tail: as the envelope decayed through
    -- the stall floor, the pan angle snapped from 0.5 to 0 in one frame.
    heavy_active = true,
}

Rumble.last_fire = Rumble.last_fire or {}

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

-- device dependent, hence configurable. below this the heavy motor just
-- stalls rather than buzzing weakly, so there is no point commanding it.
local function heavy_floor()
    local v = tonumber(Rumble.MOD.config.heavy_floor) or 15
    -- clamp covers the full plausible config range, not just the slider's.
    -- the slider tops out at 40% but a hand-edited config.lua can say 100.
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

    local peak_amt = clamp01((peak or 0) * 0.4 * (master or 1))
    local peak_left = peak_amt * math.sin(heavy * math.pi / 2)

    return peak_left >= heavy_floor()
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
            env.heavy_active = heavy_participates(env.heavy, env.peak, master)
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