-- haptics.lua - the shared frame driver. wraps update_canvas_juice once,
-- samples the raw inputs before vanilla wipes them, runs vanilla for the
-- visual juice with its own rumble write muted, then dispatches to the
-- desktop or android engine.

-- vanilla is the tested part, ours is the new part. after enough errors we
-- hand the frame back to vanilla permanently, so the player gets normal
-- rumble instead of a crash loop.

Rumble = Rumble or {}

--------------------------------------------------
------------------ TUNING -------------------------
--------------------------------------------------

local STARTUP_TTL = 20
local STARTUP_OPEN_WEIGHT = 0.40
local STARTUP_RAMP_STEP = 0.04
local STARTUP_RAMP_CAP = 0.80
local MAX_FRAME_ERRORS = 5

-- love 11.5 desktops run luajit (5.1 semantics) where it's a global. the
-- shim costs nothing and keeps this working either way.
local unpack = table.unpack or unpack

--------------------------------------------------
------------------ STATE --------------------------
--------------------------------------------------

Rumble.startup = Rumble.startup or { active = false, ramp = 0, timer = 0 }

Rumble.frame_clock = Rumble.frame_clock or 0
Rumble.last_jiggle = Rumble.last_jiggle or 0
Rumble.last_jiggle_dt = Rumble.last_jiggle_dt or 0

-- per-frame input counters. all three are consumed and cleared at the top of
-- process_frame, so an error later in the frame can never leak them into a
-- future one and double-report an input that already happened.
Rumble.click_count_frame = 0
Rumble.confirm_fired_frame = false
Rumble.destroy_count_frame = 0

Rumble.vanilla_ran = false
Rumble.frame_errors = 0
Rumble.vanilla_errors = 0
Rumble.love_update_errors = 0
Rumble.hard_disabled = false
Rumble.installed = false

-- re-entrancy guard for the card destruction hooks. held ACROSS the wrapped
-- call on purpose, so a shatter that internally routes through
-- start_dissolve counts once instead of twice.
Rumble.in_card_destroy = false

--------------------------------------------------
------------------ HELPERS ------------------------
--------------------------------------------------

local function rumble_on()
    return G and G.SETTINGS and G.SETTINGS.rumble and Rumble.master_fraction() > 0
end

-- calls vanilla's juice function. when mute is set, G.F_RUMBLE is zeroed for
-- EXACTLY that one call so vanilla's own setVibration line computes (0,0).
-- nothing goes between those three lines deliberately: if anything in that
-- window threw, G.F_RUMBLE would stay zeroed forever and quietly kill rumble
-- for every other consumer of it.
function Rumble.call_vanilla(dt, mute)
    local original = Rumble.originals and Rumble.originals.juice

    if type(original) ~= "function" then
        return false, "no original update_canvas_juice captured"
    end

    if not mute or not G then
        return xpcall(original, debug.traceback, dt)
    end

    local prev = G.F_RUMBLE
    G.F_RUMBLE = 0
    local ok, err = xpcall(original, debug.traceback, dt)
    G.F_RUMBLE = prev

    return ok, err
end

function Rumble.note_error(err)
    Rumble.frame_errors = (Rumble.frame_errors or 0) + 1

    if Rumble.frame_errors <= 3 then
        sendDebugMessage("Rumble: frame error " .. Rumble.frame_errors .. ":\n" .. tostring(err))
    end

    if Rumble.frame_errors >= MAX_FRAME_ERRORS and not Rumble.hard_disabled then
        Rumble.hard_disabled = true
        sendDebugMessage("Rumble: too many frame errors, haptics disabled for this session")

        -- graceful degradation: leave vanilla with a sane multiplier so the
        -- player still gets feedback from the base game.
        if G then
            G.F_RUMBLE = Rumble.master_fraction()
        end
    end
end

function Rumble.reset_state()
    if Rumble.desktop_env then
        Rumble.desktop_env.level = 0
        Rumble.desktop_env.peak = 0
        Rumble.desktop_env.hold = 0
    end

    if Rumble.android_cooldowns then
        for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
            Rumble.android_cooldowns[cat] = 0
        end
    end

    Rumble.android_active_until = 0
    Rumble.startup.active = false
    Rumble.startup.ramp = 0
    Rumble.startup.timer = 0
    Rumble.click_count_frame = 0
    Rumble.confirm_fired_frame = false
    Rumble.destroy_count_frame = 0
end

-- vanilla does:
--   G.ROOM.jiggle = jiggle*(1-5*dt)*(shake_amt > 0.05 and 1 or 0)
-- with screenshake off or reduced motion on, that trailing factor is 0, so
-- jiggle is ZEROED each frame rather than decayed. the correction factor has
-- to be 0 in that case too, otherwise we subtract residual that vanilla
-- already threw away and eat most of the next real delta - which silently
-- degrades hand-played, card-scoring, and blind-reveal haptics.
local function jiggle_frozen()
    if not (G and G.SETTINGS) then
        return true
    end

    if G.SETTINGS.reduced_motion then
        return true
    end

    local ss = tonumber(G.SETTINGS.screenshake)
    if not ss then
        return true
    end

    return (ss / 100 * 3) <= 0.05
end

--------------------------------------------------
------------------ FRAME BODY ---------------------
--------------------------------------------------

local function process_frame(dt)
    Rumble.frame_clock = (Rumble.frame_clock or 0) + dt

    -- sample BEFORE vanilla runs. vanilla zeroes G.VIBRATION and decays
    -- G.ROOM.jiggle inside its own body, so this is the only window where the
    -- raw numbers exist at all.
    local raw_vibration = tonumber(G.VIBRATION) or 0

    local current_jiggle = 0
    if G.ROOM then
        current_jiggle = tonumber(G.ROOM.jiggle) or 0
    end

    -- undo vanilla's decay since the previous sample. the dt used is clamped
    -- because on a frame hitch the raw dt can push the factor negative, which
    -- would make a decaying residual look like a fresh burst of scored cards
    -- - phantom haptics exactly when the game is already struggling.
    local correction
    if jiggle_frozen() then
        correction = 0
    else
        local jdt = math.min(Rumble.last_jiggle_dt or 0, 0.1)
        correction = math.max(0, 1 - 5 * jdt)
    end

    local true_added_jiggle = math.max(0, current_jiggle - Rumble.last_jiggle * correction)

    Rumble.last_jiggle = current_jiggle
    Rumble.last_jiggle_dt = dt

    -- consume every input counter immediately. if we throw later this frame
    -- they're already cleared, so nothing leaks forward.
    local click_count = Rumble.click_count_frame or 0
    local confirm_fired = Rumble.confirm_fired_frame == true
    local destroy_count = Rumble.destroy_count_frame or 0

    Rumble.click_count_frame = 0
    Rumble.confirm_fired_frame = false
    Rumble.destroy_count_frame = 0

    local fired = {}

    if confirm_fired then
        fired[#fired + 1] = { cat = "ui_confirm", count = 1 }
        Rumble.dbg("input CONFIRM -> ui_confirm")
    end

    -- a confirm also routes through the normal click path, so don't count
    -- that same click twice.
    local plain_clicks = math.max(0, click_count - (confirm_fired and 1 or 0))
    if plain_clicks > 0 then
        fired[#fired + 1] = { cat = "ui_tap", count = plain_clicks }
        Rumble.dbg("input CLICK x%d -> ui_tap", plain_clicks)
    end

    if destroy_count > 0 then
        fired[#fired + 1] = { cat = "card_destroy", count = destroy_count }
        Rumble.dbg("input DESTROY x%d -> card_destroy", destroy_count)
    end

    -- only subtract the confirm's 1.0 when the magnitude is actually present.
    -- subtracting unconditionally would eat a plain 0.6 card draw on any
    -- frame where the confirm flag happened to be set.
    local confirm_amount = 0
    if confirm_fired and raw_vibration >= 1.0 - 0.03 then
        confirm_amount = 1.0
    end

    -- each destroyed card contributed its own +1.0. subtract them so the
    -- remainder is gameplay only. this is the fix that stops two shattered
    -- cards (2.0) from being read as the title-card splash.
    local destroy_amount = destroy_count * 1.0

    local reduced_vib = math.max(0, raw_vibration - confirm_amount - destroy_amount)

    if reduced_vib > 0.01 then
        local vcat, vcount, vphase = Rumble.classify_vibration_delta(reduced_vib)

        if vcat then
            -- the splash's closing pulse is the same raw 1.0 as cash out. if
            -- the title sequence is still running it's the close. you cannot
            -- cash out during the title screen.
            if vcat == "cash_out" and Rumble.startup.active then
                vcat, vphase = "startup_card", "close"
            end

            fired[#fired + 1] = { cat = vcat, count = vcount, phase = vphase }
            Rumble.dbg("input VIB %.3f -> %s %s", raw_vibration, vcat, vphase or "")
        else
            Rumble.dbg("input VIB %.3f -> ignored", raw_vibration)
        end
    end

    -- subtract each click's 0.5 jiggle, then classify the leftovers
    local reduced_jiggle = math.max(0, true_added_jiggle - click_count * 0.5)

    if reduced_jiggle > 0.05 then
        local jcat, jcount = Rumble.classify_jiggle_delta(reduced_jiggle)

        if jcat then
            fired[#fired + 1] = { cat = jcat, count = jcount }
            Rumble.dbg("input JIGGLE %.3f -> %s x%d", true_added_jiggle, jcat, jcount)
        else
            Rumble.dbg("input JIGGLE %.3f -> ignored", true_added_jiggle)
        end
    end

    -- title card state machine. shared by both platforms since both need the
    -- ramp progression. force_weight is the phase's target amplitude.
    for _, ev in ipairs(fired) do
        if ev.cat == "startup_card" then
            if ev.phase == "open" then
                Rumble.startup.active = true
                Rumble.startup.ramp = 0
                Rumble.startup.timer = STARTUP_TTL
                ev.force_weight = STARTUP_OPEN_WEIGHT
            elseif ev.phase == "ramp" then
                if not Rumble.startup.active then
                    -- stray ramp with no open; self-heal by treating it as one
                    Rumble.startup.active = true
                    Rumble.startup.ramp = 0
                    Rumble.startup.timer = STARTUP_TTL
                end

                Rumble.startup.ramp = Rumble.startup.ramp + 1
                ev.force_weight = math.min(STARTUP_RAMP_CAP,
                    STARTUP_OPEN_WEIGHT + STARTUP_RAMP_STEP * Rumble.startup.ramp)
            elseif ev.phase == "close" then
                ev.force_weight = 1.0
                Rumble.startup.active = false
                Rumble.startup.ramp = 0
                Rumble.startup.timer = 0
            end
        end
    end

    -- give up on a sequence that never closed (skipped title, alt-tab, etc)
    if Rumble.startup.active then
        Rumble.startup.timer = Rumble.startup.timer - dt

        if Rumble.startup.timer <= 0 then
            Rumble.startup.active = false
            Rumble.startup.ramp = 0
            Rumble.dbg("startup sequence timed out")
        end
    end

    -- vanilla runs for screenshake and cursor juice, rumble muted
    local vok, verr = Rumble.call_vanilla(dt, true)
    Rumble.vanilla_ran = true

    if not vok then
        Rumble.vanilla_errors = (Rumble.vanilla_errors or 0) + 1

        if Rumble.vanilla_errors <= 3 then
            sendDebugMessage("Rumble: vanilla juice errored:\n" .. tostring(verr))
        end
    end

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

-- xpcall wrapper with a failure budget and a vanilla fallback. if our body
-- dies before vanilla got its turn we run vanilla ourselves, so screenshake
-- and cursor juice don't freeze along with the mod.
local function safe_frame(dt)
    if Rumble.hard_disabled then
        Rumble.call_vanilla(dt, false)
        return
    end

    Rumble.vanilla_ran = false

    local ok, err = xpcall(process_frame, debug.traceback, dt)

    if ok then
        return
    end

    Rumble.note_error(err)

    if not Rumble.vanilla_ran then
        local vok, verr = Rumble.call_vanilla(dt, true)

        if not vok then
            sendDebugMessage("Rumble: vanilla fallback also errored:\n" .. tostring(verr))
        end
    end
end

--------------------------------------------------
------------------ HOOKS --------------------------
--------------------------------------------------

-- captures the true originals exactly once and never again. the shared table
-- lives in _G so a mod reload keeps pointing at real vanilla functions
-- instead of re-wrapping our own previous wrappers into a stale chain.
local function capture_originals()
    local o = Rumble.originals

    o.juice = o.juice or update_canvas_juice
    o.update = o.update or love.update

    if type(UIElement) == "table" then
        o.click = o.click or UIElement.click
    end

    if type(Controller) == "table" then
        o.capture = o.capture or Controller.capture_focused_input
        o.bpu = o.bpu or Controller.button_press_update
        o.kpu = o.kpu or Controller.key_press_update
    end

    if type(Card) == "table" then
        o.dissolve = o.dissolve or Card.start_dissolve
        o.shatter = o.shatter or Card.shatter
    end
end

-- counts one destroyed card, deduping any nested call. the flag stays set
-- ACROSS the wrapped call on purpose: if Card:shatter internally routes
-- through Card:start_dissolve we want one count, not two. releasing it inside
-- a pcall guarantees a throw can't leave it stuck, which would silently drop
-- every future destroy count for the rest of the session.
local function wrap_destroy(original)
    return function(self, ...)
        if Rumble.in_card_destroy then
            return original(self, ...)
        end

        Rumble.in_card_destroy = true
        Rumble.destroy_count_frame = (Rumble.destroy_count_frame or 0) + 1

        local results = { pcall(original, self, ...) }
        Rumble.in_card_destroy = false

        if not results[1] then
            error(results[2])
        end

        return unpack(results, 2)
    end
end

function Rumble.try_install_hooks()
    if Rumble.installed then
        return true
    end

    -- someone already hooked these (previous run, hot reload). don't stack.
    if _G.__RUMBLE_HOOKS then
        Rumble.installed = true
        return true
    end

    if type(update_canvas_juice) ~= "function" then
        return false
    end

    capture_originals()

    -- main frame hook
    update_canvas_juice = function(dt)
        safe_frame(math.max(0, tonumber(dt) or 0))
    end

    -- ui click counter. chain, never replace. only real clickables count,
    -- otherwise every hover would buzz.
    if type(UIElement) == "table" and type(Rumble.originals.click) == "function" then
        local original_click = Rumble.originals.click

        UIElement.click = function(self, ...)
            local cfg = self and self.config
            if cfg and cfg.button ~= nil then
                Rumble.click_count_frame = (Rumble.click_count_frame or 0) + 1
            end
            return original_click(self, ...)
        end
    else
        sendDebugMessage("Rumble: UIElement.click missing; menu taps won't fire")
    end

    -- card destruction. two entry points, one count per card.
    if type(Rumble.originals.dissolve) == "function" then
        Card.start_dissolve = wrap_destroy(Rumble.originals.dissolve)
    end

    if type(Rumble.originals.shatter) == "function" then
        Card.shatter = wrap_destroy(Rumble.originals.shatter)
    end

    -- controller confirm ground truth for the ambiguous 1.0 vibration
    if type(Controller) == "table" and type(Rumble.originals.capture) == "function" then
        local original_capture = Rumble.originals.capture

        Controller.capture_focused_input = function(self, ...)
            local ret = original_capture(self, ...)

            if ret == true then
                Rumble.confirm_fired_frame = true

                if Rumble.dbg_enabled() then
                    Rumble.dbg("BTN capture %s", tostring((...)))
                end
            end

            return ret
        end
    end

    -- debug input logging. varargs so a signature change can't misalign, and
    -- the tostring allocation is skipped entirely when logging is off.
    if type(Controller) == "table" and type(Rumble.originals.bpu) == "function" then
        local original_bpu = Rumble.originals.bpu

        Controller.button_press_update = function(self, ...)
            if Rumble.dbg_enabled() then
                Rumble.dbg("BTN press %s", tostring((...)))
            end
            return original_bpu(self, ...)
        end
    end

    if type(Controller) == "table" and type(Rumble.originals.kpu) == "function" then
        local original_kpu = Rumble.originals.kpu

        Controller.key_press_update = function(self, ...)
            if Rumble.dbg_enabled() then
                Rumble.dbg("KEY press %s", tostring((...)))
            end
            return original_kpu(self, ...)
        end
    end

    _G.__RUMBLE_HOOKS = true
    Rumble.installed = true
    return true
end

function Rumble.install_haptics()
    if not Rumble.try_install_hooks() then
        sendDebugMessage("Rumble: update_canvas_juice not ready yet; will retry next frame")
    end
end

-- one small love.update wrapper. two jobs: retry the hook install if the game
-- wasn't ready at init, and drive the periodic debug flush. our own work goes
-- inside a pcall so this can never be the thing that takes the game down, and
-- the original is called bare so an error in it propagates exactly as it would
-- have without us.
function Rumble.install_love_update()
    if _G.__RUMBLE_LOVE_UPDATE then
        return
    end

    _G.__RUMBLE_LOVE_UPDATE = true

    local original = Rumble.originals.update or love.update
    Rumble.originals.update = original

    love.update = function(dt)
        if original then
            original(dt)
        end

        if (Rumble.love_update_errors or 0) >= MAX_FRAME_ERRORS then
            return
        end

        local ok = pcall(function()
            if not Rumble.installed then
                Rumble.try_install_hooks()
            end

            Rumble.tick_debug(dt)
        end)

        if not ok then
            Rumble.love_update_errors = (Rumble.love_update_errors or 0) + 1
        end
    end
end