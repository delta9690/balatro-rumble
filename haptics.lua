Rumble = Rumble or {}

local MAX_FRAME_ERRORS = 5
local unpack_returns = table.unpack or unpack
Rumble.event_queue = Rumble.event_queue or {}
Rumble.frame_clock = Rumble.frame_clock or 0
Rumble.click_count_frame = 0
Rumble.confirm_fired_frame = false
Rumble.frame_errors = 0
Rumble.hard_disabled = false
Rumble.installed = false
Rumble.vanilla_ran = false
Rumble.last_jiggle = Rumble.last_jiggle or 0
Rumble.last_jiggle_dt = Rumble.last_jiggle_dt or 0
Rumble.blind_reveal_pending = Rumble.blind_reveal_pending or false
Rumble.unknown_sounds = Rumble.unknown_sounds or {}
Rumble.startup_active = Rumble.startup_active or false

local function rumble_on()
    return G and G.SETTINGS and G.SETTINGS.rumble and Rumble.master_fraction() > 0
end

local function enqueue(cat, source, phase)
    if not cat then return end
    Rumble.event_queue[#Rumble.event_queue + 1] = {
        cat = cat, count = 1, phase = phase, source_tag = source
    }
end

local function in_round_eval()
    return G and G.STATE == G.STATES and G.STATE.ROUND_EVAL
end

local function observe_sound(name)
    local cat = Rumble.sound_category(name)
    if name == "coin3" then
        cat = in_round_eval() and "cash_out" or "coin"
    end
    if cat then
        enqueue(cat, "SOUND")
        if cat == "startup_open" then Rumble.startup_active = true end
        if cat == "startup_close" then Rumble.startup_active = false end
        Rumble.dbg("EVENT SOUND %s -> %s", tostring(name), cat)
    else
        if not Rumble.unknown_sounds[name] then
            Rumble.unknown_sounds[name] = true
            Rumble.dbg("ANOMALY UNKNOWN_SOUND %s", tostring(name))
        end
    end
end

local function pack_returns(...)
    local packed = { n = select("#", ...), ... }
    return packed
end

local function call_vanilla(dt, mute)
    local original = Rumble.originals and Rumble.originals.juice
    if type(original) ~= "function" then return false, "missing vanilla juice" end
    if not mute or not G then return xpcall(original, debug.traceback, dt) end
    local previous = G.F_RUMBLE
    G.F_RUMBLE = 0
    local ok, err = xpcall(original, debug.traceback, dt)
    G.F_RUMBLE = previous
    return ok, err
end

function Rumble.reset_state()
    if Rumble.reset_desktop then Rumble.reset_desktop() end
    Rumble.event_queue = {}
    Rumble.android_active_until = 0
    Rumble.click_count_frame = 0
    Rumble.confirm_fired_frame = false
    Rumble.startup_active = false
end

local function consume_events(raw_vibration, blind_reveal)
    local fired = Rumble.event_queue
    Rumble.event_queue = {}

    -- focus is STILL classification-by-magnitude (0.7 +/- a hair), the one
    -- number we could prove is independent of every presentation setting.
    -- (yes, classifying by magnitude is gross. but it's the only signal that
    -- survives every settings combo, so here we are. I also hate having to do this awfulness.)
    local FOCUS_VIB = 0.7

    if Rumble.confirm_fired_frame then
        fired[#fired + 1] = { cat = "ui_confirm", count = 1, source_tag = "CONFIRM" }
    else
        local clicks = Rumble.click_count_frame or 0
        if clicks > 0 then
            fired[#fired + 1] = { cat = "ui_tap", count = clicks, source_tag = "CLICK" }
        end
    end
    Rumble.click_count_frame = 0
    Rumble.confirm_fired_frame = false

    if raw_vibration > FOCUS_VIB - 0.03 and raw_vibration < FOCUS_VIB + 0.03 then
        fired[#fired + 1] = { cat = "ui_focus", count = 1, source_tag = "FOCUS" }
    end
    if Rumble.startup_active and math.abs(raw_vibration - 0.1) < 0.03 then
        fired[#fired + 1] = { cat = "startup_ramp", count = 1, source_tag = "STARTUP_VIBRATION" }
    end
    if Rumble.startup_active and math.abs(raw_vibration - 1.5) < 0.08 then
        fired[#fired + 1] = { cat = "startup_close", count = 1, source_tag = "STARTUP_VIBRATION" }
        Rumble.startup_active = false
    end
    if blind_reveal then
        for index = #fired, 1, -1 do
            if fired[index].cat == "card_score_chips" then
                table.remove(fired, index)
                break
            end
        end
        fired[#fired + 1] = { cat = "blind_reveal", count = 1, source_tag = "JIGGLE_GUARDED" }
    end
    return fired
end

local function process_frame(dt)
    dt = math.max(0, tonumber(dt) or 0)
    Rumble.frame_clock = Rumble.frame_clock + dt
    local raw_vibration = tonumber(G.VIBRATION) or 0
    local current_jiggle = G.ROOM and tonumber(G.ROOM.jiggle) or 0
    local previous_jiggle = Rumble.last_jiggle or 0
    local previous_dt = math.min(Rumble.last_jiggle_dt or 0, 0.1)
    local expected = previous_jiggle * math.max(0, 1 - 5 * previous_dt)
    local added_jiggle = math.max(0, current_jiggle - expected)
    Rumble.last_jiggle = current_jiggle
    Rumble.last_jiggle_dt = dt
    local blind_reveal = Rumble.blind_reveal_pending and math.abs(added_jiggle - 3) < 0.2
    if blind_reveal then Rumble.blind_reveal_pending = false end
    local fired = consume_events(raw_vibration, blind_reveal)
    if raw_vibration > 0 or #fired > 0 then
        Rumble.dbg("FRAME input vibration=%.3f events=%d", raw_vibration, #fired)
    end

    local ok, err = call_vanilla(dt, true)
    Rumble.vanilla_ran = true
    if not ok then Rumble.dbg("ANOMALY VANILLA_JUICE %s", tostring(err)) end

    local master = Rumble.master_fraction()
    G.F_RUMBLE = master
    if not rumble_on() then
        Rumble.reset_state()
        return
    end
    if Rumble.IS_ANDROID then
        Rumble.run_android(dt, fired, master)
    else
        Rumble.run_desktop(dt, fired, master)
    end
end

local function safe_frame(dt)
    if Rumble.hard_disabled then
        call_vanilla(dt, false)
        return
    end
    Rumble.vanilla_ran = false
    local ok, err = xpcall(process_frame, debug.traceback, dt)
    if ok then return end
    Rumble.frame_errors = Rumble.frame_errors + 1
    Rumble.dbg("ANOMALY FRAME_ERROR %s", tostring(err))
    if not Rumble.vanilla_ran then call_vanilla(dt, true) end
    if Rumble.frame_errors >= MAX_FRAME_ERRORS then
        Rumble.hard_disabled = true
        G.F_RUMBLE = Rumble.master_fraction()
        Rumble.dbg("FAILOVER VANILLA")
    end
end

local function capture_originals()
    local o = Rumble.originals
    o.juice = o.juice or update_canvas_juice
    o.update = o.update or love.update
    o.sound = o.sound or play_sound
    if type(Blind) == "table" then o.set_blind = o.set_blind or Blind.set_blind end
    if type(UIElement) == "table" then o.click = o.click or UIElement.click end
    if type(Controller) == "table" then
        o.capture = o.capture or Controller.capture_focused_input
        o.bpu = o.bpu or Controller.button_press_update
        o.kpu = o.kpu or Controller.key_press_update
    end
end

function Rumble.try_install_hooks()
    if Rumble.installed then return true end
    if _G.__RUMBLE_HOOKS then Rumble.installed = true return true end
        if type(update_canvas_juice) ~= "function" or type(play_sound) ~= "function" then
            return false
        end
    capture_originals()

    update_canvas_juice = function(dt)
        safe_frame(dt)
    end

    if type(Rumble.originals.sound) == "function" then
        play_sound = function(...)
            local args = { ... }
            local name = args[1]
            local ok = pcall(observe_sound, name)
            if not ok then Rumble.dbg("ANOMALY SOUND_OBSERVER") end
            local result = pack_returns(Rumble.originals.sound(...))
            return unpack_returns(result, 1, result.n)
        end
    end

    if type(Blind) == "table" and type(Rumble.originals.set_blind) == "function" then
        Blind.set_blind = function(self, blind, reset, silent, ...)
            if not reset and not silent then Rumble.blind_reveal_pending = true end
            return Rumble.originals.set_blind(self, blind, reset, silent, ...)
        end
    end

    if type(UIElement) == "table" and type(Rumble.originals.click) == "function" then
        UIElement.click = function(self, ...)
            if self and self.config and self.config.button ~= nil then
                Rumble.click_count_frame = Rumble.click_count_frame + 1
            end
            return Rumble.originals.click(self, ...)
        end
    end

    if type(Controller) == "table" and type(Rumble.originals.capture) == "function" then
        Controller.capture_focused_input = function(self, ...)
            local result = Rumble.originals.capture(self, ...)
            local button = select(1, ...)
            local input_type = select(2, ...)
            local is_confirm = input_type == "press"
                and (button == "a" or button == "leftshoulder" or button == "rightshoulder")
            if result == true and is_confirm then
                Rumble.confirm_fired_frame = true
                Rumble.dbg("CONTROLLER confirm button=%s", tostring(button))
            elseif result == true then
                Rumble.dbg("CONTROLLER capture button=%s type=%s",
                    tostring(button), tostring(input_type))
            end
            return result
        end
    end

    if type(Controller) == "table" and type(Rumble.originals.bpu) == "function" then
        Controller.button_press_update = function(self, ...)
            local button = select(1, ...)
            Rumble.dbg("CONTROLLER press button=%s", tostring(button))
            local result = Rumble.originals.bpu(self, ...)
            return result
        end
    end
    if type(Controller) == "table" and type(Rumble.originals.kpu) == "function" then
        Controller.key_press_update = function(self, ...)
            local key = select(1, ...)
            Rumble.dbg("CONTROLLER key key=%s", tostring(key))
            local result = Rumble.originals.kpu(self, ...)
            return result
        end
    end
    _G.__RUMBLE_HOOKS = true
    Rumble.installed = true
    return true
end

function Rumble.install_haptics()
    if not Rumble.try_install_hooks() then
        sendDebugMessage("Rumble: haptic hooks waiting for game functions")
    end
end

function Rumble.install_love_update()
    if _G.__RUMBLE_LOVE_UPDATE then return end
    local original = Rumble.originals.update or love.update
    if type(original) ~= "function" then return end
    _G.__RUMBLE_LOVE_UPDATE = true
    Rumble.originals.update = original
    love.update = function(dt)
        original(dt)
        pcall(function()
            if not Rumble.funcs_installed then Rumble.try_install_funcs() end
            if not Rumble.installed then Rumble.try_install_hooks() end
            Rumble.tick_debug(dt)
        end)
    end
end
