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
}

Rumble.last_fire = Rumble.last_fire or {}

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

-- device dependent, hence configurable. below this the heavy motor just
-- stalls rather than buzzing weakly, so there is no point commanding it.
local function heavy_floor()
    local pct = tonumber(Rumble.MOD.config.heavy_stall_floor) or 15
    return math.max(0, math.min(0.6, pct / 100))
end

local function heavy_gate_on()
    return Rumble.MOD.config.heavy_gate ~= false
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

    -- constant-power crossfade
    local t = env.heavy or 0.5
    local left = clamp01(amt * math.sin(t * math.pi / 2))
    local right = clamp01(amt * math.cos(t * math.pi / 2))

    -- heavy stall gate. if the heavy channel comes in under the floor, hand
    -- that energy to the light motor instead of commanding a stalled one.
    -- total power is preserved - the event just gets rendered by the motor
    -- that can actually render it. this is the difference between a crisp
    -- tick and a dying buzz on every low-weight, high-repeat event.
    local floor = heavy_floor()
    if heavy_gate_on() and left > 0 and left < floor then
        right = clamp01(right + left)
        left = 0
    end

    if Rumble.dbg_enabled() and (left > 0 or right > 0) then
        Rumble.dbg("desktop COMMAND L=%.3f R=%.3f", left, right)
    end

    apply_rumble(left, right)
end