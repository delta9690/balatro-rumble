-- metadata lives in Rumble.json.
--
-- do NOT put a --- STEAMODDED HEADER block back in this file. steamodded
-- would read both sources and try to load the mod twice, which crashes with:
--     attempt to index field 'INIT' (a nil value)
-- the old header compat path also broke config loading, because the JSON
-- path is what registers config.lua.



if not Rumble then
    Rumble = {}
end

Rumble.MOD = SMODS.current_mod
Rumble.path = Rumble.MOD.path or ""

-- shared across mod reloads on purpose. if steamodded re-executes these
-- files we want the TRUE original functions to survive, not to re-wrap our
-- own wrappers into a stale nested chain.
_G.__RUMBLE_ORIGINALS = _G.__RUMBLE_ORIGINALS or {}
Rumble.originals = _G.__RUMBLE_ORIGINALS

--------------------------------------------------
------------------ PLATFORM ----------------------
--------------------------------------------------

-- proton/wine reports itself as "Windows" through love.system.getOS(), which
-- turns every bug report into a guessing game. these env vars are set by
-- steam's compatibility layer and absent on real windows.
local WINE_MARKERS = {
    "STEAM_COMPAT_DATA_PATH",
    "STEAM_COMPAT_CLIENT_INSTALL_PATH",
    "PROTON_LOG",
    "WINEPREFIX",
    "WINELOADERNOEXEC",
    "WINEDLLOVERRIDES",
}

local function detect_proton_wine(os_name)
    if os_name ~= "Windows" then
        return false, "OS is " .. os_name
    end

    for _, name in ipairs(WINE_MARKERS) do
        local ok, value = pcall(os.getenv, name)
        if ok and type(value) == "string" and value ~= "" then
            return true, name .. " is set"
        end
    end

    return false, "no wine/proton marker found"
end

local OS_NAME = love.system.getOS()

Rumble.OS_NAME = OS_NAME
Rumble.IS_ANDROID = OS_NAME == "Android"
Rumble.IS_PROTON_WINE, Rumble.PROTON_REASON = detect_proton_wine(OS_NAME)

function Rumble.platform_label()
    if Rumble.IS_PROTON_WINE then
        return Rumble.OS_NAME .. " (Proton/Wine)"
    end
    return Rumble.OS_NAME
end

--------------------------------------------------
------------------ DEBUG LOG ----------------------
--------------------------------------------------

-- one current file plus one .old backup. lines capped, buffer capped, file
-- capped. ALL log state lives in this file - an earlier version moved the
-- flush timer out of here while haptics.lua still poked at it, which is
-- exactly how we got "arithmetic on nil" on the first frame with a
-- non-empty buffer.
local LOG_NAME = "rumble_debug.log"
local LOG_OLD_NAME = "rumble_debug_old.log"
local LOG_MAX_BYTES = 1024 * 1024 * 2
local LOG_MAX_LINE = 400
local LOG_MAX_BUFFER = 200
local LOG_FLUSH_INTERVAL = 1.0

Rumble.debug_buffer = Rumble.debug_buffer or {}
Rumble.debug_flush_timer = Rumble.debug_flush_timer or 0

function Rumble.dbg_enabled()
    local cfg = Rumble.MOD and Rumble.MOD.config
    return cfg ~= nil and cfg.debug_log == true
end

-- compatibility helper for older call sites that still check `verbose`.
function Rumble.verbose()
    return Rumble.dbg_enabled()
end

-- safe by construction: the format call itself is inside pcall, so a bad
-- format string or a nil argument logs nothing instead of taking the frame
-- down with it. this gets called from inside the update loop, so "logs
-- nothing" is very much the preferred failure mode.
function Rumble.dbg(fmt, ...)
    if not Rumble.dbg_enabled() then
        return
    end

    local t = 0
    if G and G.TIMERS and type(G.TIMERS.REAL) == "number" then
        t = G.TIMERS.REAL
    end

    local ok, line = pcall(string.format, "[%8.2f] " .. fmt, t, ...)
    if not ok or type(line) ~= "string" then
        return
    end

    if #line > LOG_MAX_LINE then
        line = line:sub(1, LOG_MAX_LINE) .. "..."
    end

    Rumble.debug_buffer[#Rumble.debug_buffer + 1] = line

    if #Rumble.debug_buffer > LOG_MAX_BUFFER then
        Rumble.flush_debug()
    end
end

function Rumble.flush_debug()
    if #Rumble.debug_buffer == 0 then
        return
    end

    local text = table.concat(Rumble.debug_buffer, "\n") .. "\n"
    Rumble.debug_buffer = {}

    local ok, err = pcall(function()
        local info = love.filesystem.getInfo(LOG_NAME)

        if info and info.size and info.size > LOG_MAX_BYTES then
            love.filesystem.remove(LOG_OLD_NAME)
            local old = love.filesystem.read(LOG_NAME)
            if old then
                love.filesystem.write(LOG_OLD_NAME, old)
            end
            love.filesystem.write(LOG_NAME, "")
        end

        love.filesystem.append(LOG_NAME, text)
    end)

    if not ok then
        sendDebugMessage("Rumble: couldn't write debug log: " .. tostring(err))
    end
end

-- called once at init so a fresh session doesn't tail onto last run's log.
function Rumble.debug_init()
    pcall(function()
        if love.filesystem.getInfo(LOG_NAME) then
            love.filesystem.remove(LOG_OLD_NAME)
            local old = love.filesystem.read(LOG_NAME)
            if old then
                love.filesystem.write(LOG_OLD_NAME, old)
            end
            love.filesystem.write(LOG_NAME, "")
        end
    end)

    Rumble.debug_buffer = {}
    Rumble.debug_flush_timer = 0
end

-- periodic flush. this is the line that used to explode.
function Rumble.tick_debug(dt)
    if not Rumble.dbg_enabled() then
        Rumble.debug_flush_timer = 0
        return
    end

    Rumble.debug_flush_timer = (Rumble.debug_flush_timer or 0) + (tonumber(dt) or 0)

    if Rumble.debug_flush_timer >= LOG_FLUSH_INTERVAL then
        Rumble.debug_flush_timer = 0
        Rumble.flush_debug()
    end
end

--------------------------------------------------
------------------ CONFIGURATION ------------------
--------------------------------------------------

Rumble.DEFAULTS = {
    master_strength = 100,
    desktop_hold_ms = 60,
    desktop_light_hold_ms = 60,
    desktop_heavy_hold_ms = 90,
    heavy_min_impulse_ms = 80,
    android_min_pulse_ms = 12,
    android_settle_ms = 50,
    debug_log = false,
    heavy_stall_floor = 15,
    heavy_gate = true,
}

function Rumble.ensure_config()
    if type(Rumble.MOD.config) ~= "table" then
        Rumble.MOD.config = {}
    end

    local c = Rumble.MOD.config

    for key, default in pairs(Rumble.DEFAULTS) do
        if c[key] == nil then
            c[key] = default
        end
    end

    if type(c.desktop_light_hold_ms) ~= "number" then
        c.desktop_light_hold_ms = tonumber(c.desktop_hold_ms) or Rumble.DEFAULTS.desktop_light_hold_ms
    end

    if type(c.desktop_heavy_hold_ms) ~= "number" then
        c.desktop_heavy_hold_ms = tonumber(c.desktop_hold_ms) or Rumble.DEFAULTS.desktop_heavy_hold_ms
    end

    for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
        local meta = Rumble.CATEGORY_DEFAULTS[cat]

        if type(c[cat .. "_enabled"]) ~= "boolean" then
            c[cat .. "_enabled"] = true
        end

        if type(c[cat .. "_strength"]) ~= "number" then
            c[cat .. "_strength"] = 100
        end

        if type(c[cat .. "_decay"]) ~= "number" then
            c[cat .. "_decay"] = meta.default_decay
        end

        if type(c[cat .. "_duration_ms"]) ~= "number" then
            c[cat .. "_duration_ms"] = meta.default_duration_ms
        end

        if type(c[cat .. "_min_retrigger_ms"]) ~= "number" then
            c[cat .. "_min_retrigger_ms"] = (meta.default_min_retrigger_s or 0) * 1000
        end

        if type(c[cat .. "_motor_profile_index"]) ~= "number" then
            c[cat .. "_motor_profile_index"] = Rumble.cat_motor_index(cat)
        end
    end
end

function Rumble.master_fraction()
    Rumble.ensure_config()
    local v = math.max(0, math.min(100, Rumble.MOD.config.master_strength or 100))
    v = math.floor(v / 10 + 0.5) * 10
    return v / 100
end

function Rumble.hold_s()
    return Rumble.hold_light_s()
end

function Rumble.hold_light_s()
    return math.max(0, (Rumble.MOD.config.desktop_light_hold_ms or 60) / 1000)
end

function Rumble.hold_heavy_s()
    return math.max(0, (Rumble.MOD.config.desktop_heavy_hold_ms or 90) / 1000)
end

function Rumble.heavy_min_impulse_s()
    return math.max(0, (Rumble.MOD.config.heavy_min_impulse_ms or 80) / 1000)
end

function Rumble.min_pulse()
    return math.max(0.001, (Rumble.MOD.config.android_min_pulse_ms or 12) / 1000)
end

function Rumble.settle()
    return math.max(0, (Rumble.MOD.config.android_settle_ms or 50) / 1000)
end

-- every one of these defaults to a sensible value, never "off". defaulting
-- nil to off is what silently killed desktop rumble for a whole version: a
-- missing key read as false and our zeroed write clobbered vanilla's real
-- one every frame. do not get cute and change that back.
function Rumble.cat_enabled(cat)
    local v = Rumble.MOD.config[cat .. "_enabled"]
    if v == nil then
        return true
    end
    return v == true
end

function Rumble.cat_strength(cat)
    local v = Rumble.MOD.config[cat .. "_strength"]
    if type(v) ~= "number" then
        v = 100
    end
    return v
end

function Rumble.cat_decay(cat)
    local v = Rumble.MOD.config[cat .. "_decay"]
    if type(v) ~= "number" then
        v = Rumble.CATEGORY_DEFAULTS[cat].default_decay
    end
    return v
end

function Rumble.cat_duration(cat)
    local v = Rumble.MOD.config[cat .. "_duration_ms"]
    if type(v) ~= "number" then
        v = Rumble.CATEGORY_DEFAULTS[cat].default_duration_ms
    end
    return v / 1000
end

function Rumble.cat_min_retrigger(cat)
    local v = Rumble.MOD.config[cat .. "_min_retrigger_ms"]
    if type(v) ~= "number" then
        v = (Rumble.CATEGORY_DEFAULTS[cat].default_min_retrigger_s or 0) * 1000
    end
    return v / 1000
end

--------------------------------------------------
------------------ FILE LOADING -------------------
--------------------------------------------------

-- the id is passed explicitly. without it SMODS.load_file only works while
-- SMODS.current_mod is set, which is true during load but not necessarily on
-- any later retry path. passing it costs nothing and removes the assumption.
local function boot_file(name)
    local chunk, err = SMODS.load_file(name, Rumble.MOD.id)
    assert(chunk, err)()
    sendDebugMessage("Rumble: loaded " .. name)
end

-- order matters: categories first (constants everything else reads), then
-- the two platform engines, then the shared frame driver, then the menus.
boot_file("categories.lua")
boot_file("desktop.lua")
boot_file("android.lua")
boot_file("haptics.lua")
boot_file("ui.lua")

--------------------------------------------------
------------------ INIT ---------------------------
--------------------------------------------------

-- THIS is the init. top level scope, no SMODS.INIT wrapper. see the comment
-- at the top of the file for why.

Rumble.ensure_config()
Rumble.debug_init()

-- ui definitions are safe here (they only assign fields), but the G.FUNCS
-- callbacks they reference retry below: we can be running before the game
-- has built G.FUNCS.
Rumble.install_ui()
Rumble.try_install_funcs()

-- update_canvas_juice may not exist yet either - it lives in the game's own
-- function files, which may not be loaded at this point. install_haptics
-- returns quietly in that case and the love.update wrapper keeps retrying.
Rumble.install_haptics()

-- always installed, regardless of whether the juice hook succeeded, because
-- it also drives the retries and the debug flush.
Rumble.install_love_update()

sendDebugMessage("Rumble v5 loaded (" .. Rumble.platform_label()
    .. (Rumble.IS_PROTON_WINE and (": " .. Rumble.PROTON_REASON) or "") .. ")")