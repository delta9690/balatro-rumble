Rumble = Rumble or {}

Rumble.desktop_channels = Rumble.desktop_channels or {
    heavy = { level = 0, hold = 0, decay = 1, cat = nil, assist_until = 0 },
    light = { level = 0, hold = 0, decay = 1, cat = nil, kick_until = 0, infill = 0, infill_decay = 0 }
}
Rumble.last_event_time = Rumble.last_event_time or {}
Rumble.last_commands = Rumble.last_commands or { heavy = -1, light = -1 }

local function clamp01(value)
    return math.max(0, math.min(1, value or 0))
end

-- 0.008 is the "don't be an asshole to the hardware" threshold: skip the
-- write unless the command actually changed by more than this, otherwise we
-- spam setVibration every frame with the same number and some pads hate that.
local SOAK_THRESHOLD = 0.008

local function apply_rumble(heavy, light)
    local gamepad = G and G.CONTROLLER and G.CONTROLLER.GAMEPAD
    local pad = gamepad and gamepad.object
    if not pad then return end
    local should_write = math.abs(heavy - (Rumble.last_commands.heavy or -1)) > SOAK_THRESHOLD
        or math.abs(light - (Rumble.last_commands.light or -1)) > SOAK_THRESHOLD
    -- Never skip the final write down to zero: if a channel is already stopped
    -- but we're supposed to be at rest, still send it so the motor actually
    -- halts instead of sitting at a residual like 0.006 forever.
    local must_zero = (heavy == 0 and (Rumble.last_commands.heavy or 0) ~= 0)
        or (light == 0 and (Rumble.last_commands.light or 0) ~= 0)
    if not should_write and not must_zero then return end

    local ok, err = pcall(function()
        if type(pad.isConnected) == "function" and not pad:isConnected() then
            Rumble.reset_desktop()
            return
        end
        pad:setVibration(heavy, light)
        Rumble.last_commands.heavy = heavy
        Rumble.last_commands.light = light
    end)
    if not ok then
        Rumble.dbg("desktop ANOMALY RUMBLE_WRITE heavy=%.3f light=%.3f err=%s",
            heavy, light, tostring(err))
    elseif Rumble.last_commands.heavy == heavy and Rumble.last_commands.light == light then
        Rumble.dbg("desktop WRITE heavy=%.3f light=%.3f", heavy, light)
    end
end

function Rumble.reset_desktop()
    for _, channel in pairs(Rumble.desktop_channels) do
        channel.level, channel.hold, channel.cat = 0, 0, nil
        channel.kick_until, channel.assist_until = 0, 0
        channel.infill, channel.infill_decay = 0, 0
    end
    Rumble.last_commands.heavy, Rumble.last_commands.light = 0, 0
    Rumble.last_assist, Rumble.last_kick_light = false, false
end

local function route(cat, contribution, heavy, light)
    local heavy_bleed, light_bleed = Rumble.cat_profile(cat)
    local primary_heavy = heavy_bleed >= light_bleed
    local primary = primary_heavy and heavy_bleed or light_bleed
    local secondary = primary_heavy and light_bleed or heavy_bleed
    local floor_primary = primary_heavy and (Rumble.MOD.config.heavy_floor or 15)
        or (Rumble.MOD.config.light_floor or 8)
    local floor_secondary = primary_heavy and (Rumble.MOD.config.light_floor or 8)
        or (Rumble.MOD.config.heavy_floor or 15)
    local primary_value = contribution * primary
    local secondary_value = contribution * secondary

    local fallback = false
    if primary_value * 100 < floor_primary and secondary_value * 100 >= floor_secondary then
        primary_value, secondary_value = secondary_value, 0
        primary_heavy = not primary_heavy
        fallback = true
    end
    if primary_heavy then
        heavy, light = math.max(heavy, primary_value), math.max(light, secondary_value)
    else
        light, heavy = math.max(light, primary_value), math.max(heavy, secondary_value)
    end
    return heavy, light, primary_heavy, fallback, heavy_bleed, light_bleed
end

-- Returns the game-speed-scaled minimum gap, in seconds, between distinct
-- ticks for a category. Below this gap (i.e. events arriving faster) we treat
-- the stream as a sustained pulse and smooth it instead of re-ticking.
local function tick_gap_s(cat)
    local base = Rumble.cat_min_retrigger(cat)
    if base <= 0 then base = 0.018 end
    local speed = 1
    if G and type(G.SPEEDFACTOR) == "number" and G.SPEEDFACTOR > 0 then
        speed = G.SPEEDFACTOR
    end
    return math.max(base, base / math.max(1, speed))
end

-- Large-motor spinup assist fires a momentary boost on the heavy channel for
-- effects that primarily use the large motor, provided the heavy command is
-- actually above its floor (no gating has been tripped). This is the universal
-- "get the large rotor up to speed" control.
local function spinup_assist_on()
    return Rumble.MOD.config.spinup_assist ~= false
end

-- Each motor channel decays independently. The heavy and light channels share
-- this EXACT envelope math, except the light channel ALSO carries a separate
-- "infill" term that fills the gap while the large rotor spins up. That infill
-- deserves its own decay curve, so it lives alongside here rather than being
-- folded into the main level (folding it in made infill permanent, which felt
-- like the motor was stuck on - no thanks).
local function decay_channel(channel, dt, has_infill)
    if channel.hold > 0 then
        channel.hold = math.max(0, channel.hold - dt)
    else
        channel.level = channel.level * math.exp(-channel.decay * math.min(dt, 0.1))
        if channel.level < 0.002 then
            channel.level = 0
            channel.cat = nil
            channel.kick_until = 0
        end
    end
    if has_infill and channel.infill > 0 then
        local rate = channel.infill_decay > 0 and channel.infill_decay or 20
        channel.infill = channel.infill * math.exp(-rate * math.min(dt, 0.1))
        if channel.infill < 0.002 then channel.infill = 0 end
    end
end

function Rumble.run_desktop(dt, fired, master)
    local now = Rumble.frame_clock or 0
    local requested_heavy, requested_light = 0, 0
    local heavy_cat, light_cat = "(none)", "(none)"
    local dispatched = false
    local sustain_heavy, sustain_light = false, false

    for _, ev in ipairs(fired) do
        if Rumble.cat_enabled(ev.cat) then
            local since = now - (Rumble.last_event_time[ev.cat] or -999)
            local gap = tick_gap_s(ev.cat)
            local contribution = Rumble.cat_power(ev.cat)
            local profile_index = Rumble.MOD.config[ev.cat .. "_motor_profile"] or 3
            local profile_name = Rumble.MOTOR_PROFILES[profile_index] or "Balanced"
            local heavy_bleed, light_bleed = Rumble.cat_profile(ev.cat)
            local primary_heavy = heavy_bleed >= light_bleed

            dispatched = true
            Rumble.last_event_time[ev.cat] = now

            Rumble.dbg("desktop DISPATCH %s count=%d power=%.3f profile=%s smooth=%s source=%s",
                ev.cat, ev.count or 1, contribution, profile_name,
                tostring(since < gap), ev.source_tag or "UNKNOWN")

            local prev_heavy, prev_light = requested_heavy, requested_light
            local h, l = route(ev.cat, contribution, prev_heavy, prev_light)
            requested_heavy, requested_light = h, l

            -- Strongest-wins attribution. Profile bleed means ONE event can
            -- raise BOTH channels, so tag a channel's category only when THIS
            -- event actually pushed that channel higher (route() already
            -- maxes, so h/l only strictly exceed prev when this event won).
            -- Otherwise, when several categories fire in one frame, the last
            -- event's decay would overwrite the one that truly owned the peak.
            if h > prev_heavy then heavy_cat = ev.cat end
            if l > prev_light then light_cat = ev.cat end

            if since >= gap then
                -- Spaced-out event -> a distinct tick.
                if primary_heavy then
                    if contribution * 100 >= (Rumble.MOD.config.heavy_floor or 15)
                        and spinup_assist_on() then
                        local window = (Rumble.MOD.config.assist_window_ms or 30) / 1000
                        Rumble.desktop_channels.heavy.assist_until = now + window
                    end
                else
                    if Rumble.MOD.config[ev.cat .. "_kick"] ~= false then
                        local window = (Rumble.MOD.config.kick_window_ms or 25) / 1000
                        Rumble.desktop_channels.light.kick_until = now + window
                    end
                end
            else
                -- Fast stream -> sustained rumble; keep the primary channel pinned.
                if primary_heavy then sustain_heavy = true else sustain_light = true end
            end
        end
    end

    local heavy_channel = Rumble.desktop_channels.heavy
    local light_channel = Rumble.desktop_channels.light

    -- Heavy channel envelope (carries the large-motor command).
    if requested_heavy > heavy_channel.level then
        heavy_channel.level = clamp01(requested_heavy)
        heavy_channel.cat = heavy_cat
        heavy_channel.decay = Rumble.cat_decay(heavy_cat)
        heavy_channel.hold = Rumble.hold_s(true)
    end

    -- Light channel envelope, plus the separate infill layer that fills the gap
    -- while the large motor spins up and then blends out.
    if requested_light > light_channel.level then
        light_channel.level = clamp01(requested_light)
        light_channel.cat = light_cat
        light_channel.decay = Rumble.cat_decay(light_cat)
        light_channel.hold = Rumble.hold_s(false)
    end
    -- A fast stream holds the affected channel at its current level so it reads
    -- as a smooth rumble, and only begins the normal decay once events stop.
    if sustain_heavy then heavy_channel.hold = Rumble.hold_s(true) end
    if sustain_light then light_channel.hold = Rumble.hold_s(false) end
    if requested_heavy > 0 and Rumble.MOD.config.onset_supplement ~= false
        and light_channel.cat and heavy_channel.level > 0 then
        local target = clamp01(requested_heavy
            * (Rumble.MOD.config.onset_supplement_level or 35) / 100)
        if target > light_channel.infill then
            light_channel.infill = target
            light_channel.infill_decay = 1 / math.max(0.01, (Rumble.MOD.config.onset_supplement_ms or 60) / 1000)
        end
    end

    for _, item in ipairs({
        { channel = heavy_channel },
        { channel = light_channel, has_infill = true }
    }) do
        decay_channel(item.channel, dt, item.has_infill)
    end

    local heavy = heavy_channel.level
    local light = light_channel.level + light_channel.infill

    -- Apply the large-motor spinup assist (momentary 100% to accelerate the
    -- rotor). This is separate from the light-channel tap kick.
    local assist_active = heavy_channel.assist_until > now
    if assist_active then
        heavy = 1
    end

    -- Apply the light-channel tap kick for sharp-effects.
    local kick_light = light_channel.kick_until > now
    if kick_light then
        local mode = Rumble.MOD.config.kick_mode or "multiplicative"
        light = mode == "absolute" and 1 or clamp01(light) * (1 + (Rumble.MOD.config.kick_amount or 35) / 100)
    end

    heavy = clamp01(heavy) * master
    light = clamp01(light) * master

    -- Whether the final heavy command clears the large-motor minimum duty
    -- floor. Below this the motor physically can't sustain a spin, so we flag
    -- it here for the log rather than leaving readers to guess from the raw
    -- number.
    local pass_heavy_floor = heavy >= ((Rumble.MOD.config.heavy_floor or 15) / 100)

    if dispatched or assist_active ~= Rumble.last_assist or kick_light ~= Rumble.last_kick_light then
        Rumble.dbg("desktop ASSEMBLY heavy_cat=%s light_cat=%s duty_ok=%s assist=%s "
            .. "infill=%.3f tap_kick=%s master=%.3f -> heavy=%.3f light=%.3f",
            heavy_channel.cat or heavy_cat, light_channel.cat or light_cat,
            tostring(pass_heavy_floor), tostring(assist_active),
            light_channel.infill, tostring(kick_light),
            master, heavy, light)
    end
    Rumble.last_assist = assist_active
    Rumble.last_kick_light = kick_light

    apply_rumble(heavy, light)
end
