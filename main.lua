-- metadata lives in Rumble.json. two things to NEVER put back in this file:
--   1. a --- STEAMODDED HEADER block (steamodded would load the mod twice, and
--      not in a cute way)
--   2. any reference to SMODS.INIT
--
-- SMODS.INIT got murdered in steamodded 1.0.0+, which is the exact moment
-- "attempt to index field 'INIT' (a nil value)" started showing its ugly head.
-- the loader flags SMODS.INIT as a crusty 0.9.8 pattern, and old builds
-- papered over it with a compat shim that built the table behind your back.
-- legacy header detection tripped that shim; json metadata does not. top
-- level scope is the init now. fight me, migration guide agrees.
--
-- bonus round: that same outdated path nukes mod.config and skips
-- load_mod_config, so dropping it ALSO made config loading start working.
-- two birds, one rage edit.

-- it is much easier to code against something when you have the latest version of it installed.

if not Rumble then
    Rumble = {}
end

Rumble.MOD = SMODS.current_mod
Rumble.path = Rumble.MOD.path or ""

-- shared across mod reloads on purpose. when steamodded re-runs these files
-- (and oh, it will) we want the REAL originals to live, not to wrap our own
-- wrappers into a six-deep nesting-doll of stale hooks.
_G.__RUMBLE_ORIGINALS = _G.__RUMBLE_ORIGINALS or {}
Rumble.originals = _G.__RUMBLE_ORIGINALS

--------------------------------------------------
------------------ PLATFORM ----------------------
--------------------------------------------------

-- proton/wine LIES about being "Windows" through love.system.getOS(), which
-- turns every bug report into a riddle. these env vars are set by steam's
-- compat layer and simply don't exist on real windows. so we sniff for them. 
-- proton likes to do strange things to the controller behaviour sometimes.
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

-- one live file + one .old backup. lines capped, buffer capped, file capped.
-- ALL of the log state lives HERE to avoid flushing during a write and crashing
local LOG_NAME = "rumble_debug.log"
local LOG_OLD_NAME = "rumble_debug_old.log"
local LOG_MAX_BYTES = 1024 * 1024 * 16
local LOG_MAX_LINE = 2000
local LOG_MAX_BUFFER = 1000
local LOG_FLUSH_INTERVAL = 2.0

Rumble.debug_buffer = Rumble.debug_buffer or {}
Rumble.debug_flush_timer = Rumble.debug_flush_timer or 0

function Rumble.dbg_enabled()
    local cfg = Rumble.MOD and Rumble.MOD.config
    return cfg ~= nil and cfg.debug_log == true
end

-- safe by construction: the string.format call is inside a pcall, so a bad
-- format string or a nil arg logs nothing instead of nuking the whole frame.
-- this runs inside the update loop, so "logs nothing" is 100% the failure
-- mode i want, not a bug.
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

-- make sure we dont double send the header lines
Rumble.header_written = Rumble.header_written or false

function Rumble.debug_header()
    local mod = Rumble.MOD or {}
    local name = mod.name or mod.display_name or "Rumble"
    local version = tostring(mod.version or "?")
    local author = ""
    local a = mod.author
    if type(a) == "table" then author = table.concat(a, ", ")
    elseif type(a) == "string" then author = a end

    local backend = Rumble.IS_ANDROID and "Android (single-motor)" or "Desktop (dual-motor)"

    local lines = {
        "==================== RUMBLE ====================",
        ("mod      %s v%s"):format(name, version),
    }
    if author ~= "" then lines[#lines + 1] = ("author   %s"):format(author) end
    lines[#lines + 1] = ("engine   %s"):format(Rumble.ENGINE_VERSION or "?")
    lines[#lines + 1] = ("os       %s"):format(Rumble.platform_label())
    lines[#lines + 1] = ("backend  %s"):format(backend)
    lines[#lines + 1] = "================================================="
    return lines
end

function Rumble.flush_debug()
    if #Rumble.debug_buffer == 0 then
        return
    end

    local text
    if not Rumble.header_written then
        Rumble.header_written = true
        text = table.concat(Rumble.debug_header(), "\n") .. "\n"
            .. table.concat(Rumble.debug_buffer, "\n") .. "\n"
    else
        text = table.concat(Rumble.debug_buffer, "\n") .. "\n"
    end
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

-- called once at init so a new session doesn't pile on top of the previous run's log
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
    heavy_hold_ms = 90,
    light_hold_ms = 60,
    heavy_floor = 15,
    light_floor = 8,
    onset_supplement = true,
    onset_supplement_ms = 60,
    onset_supplement_level = 35,
    kick_mode = "multiplicative",
    kick_amount = 35,
    kick_window_ms = 25,
    spinup_assist = true,
    assist_window_ms = 30,
    flame_enabled = true,
    score_scaling_enabled = false,
    debug_log = false,
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

    for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
        local meta = Rumble.CATEGORY_DEFAULTS[cat]

        if type(c[cat .. "_enabled"]) ~= "boolean" then
            c[cat .. "_enabled"] = true
        end

        if type(c[cat .. "_power"]) ~= "number" then
            c[cat .. "_power"] = meta.power
        end

        if type(c[cat .. "_decay"]) ~= "number" then
            c[cat .. "_decay"] = meta.decay
        end

        if type(c[cat .. "_duration_ms"]) ~= "number" then
            c[cat .. "_duration_ms"] = meta.duration
        end

        if type(c[cat .. "_min_retrigger_ms"]) ~= "number" then
            c[cat .. "_min_retrigger_ms"] = 0
        end

        if type(c[cat .. "_kick"]) ~= "boolean" then
            c[cat .. "_kick"] = true
        end

        if type(c[cat .. "_motor_profile"]) ~= "number" then
            c[cat .. "_motor_profile"] = meta.profile
        end
    end
end

function Rumble.master_fraction()
    Rumble.ensure_config()
    local v = math.max(0, math.min(100, Rumble.MOD.config.master_strength or 100))
    v = math.floor(v / 10 + 0.5) * 10
    return v / 100
end

function Rumble.hold_s(heavy)
    local key = heavy and "heavy_hold_ms" or "light_hold_ms"
    return math.max(0, (Rumble.MOD.config[key] or (heavy and 90 or 60)) / 1000)
end

-- the per-category getters (cat_power, cat_enabled, cat_decay, cat_duration,
-- cat_min_retrigger, cat_profile) live in categories.lua, right next to the
-- CATEGORY_DEFAULTS table they read

--------------------------------------------------
------------------ FILE LOADING -------------------
--------------------------------------------------

-- the id is passed explicitly. without it SMODS.load_file only works while
-- SMODS.current_mod is set, which is true during load but NOT guaranteed on
-- a later retry path. passing it costs nothing and stops me having to think
-- about timing
local function boot_file(name)
    local chunk, err = SMODS.load_file(name, Rumble.MOD.id)
    assert(chunk, err)()
    sendDebugMessage("Rumble: loaded " .. name)
end

-- order matters: categories first (everyone reads its constants), then the
-- two platform engines, then the shared frame driver, then the menus
boot_file("categories.lua")
boot_file("desktop.lua")
boot_file("android.lua")
boot_file("haptics.lua")
boot_file("ui.lua")

--------------------------------------------------
------------------ INIT ---------------------------
--------------------------------------------------

-- THIS is the init. top level scope, no SMODS.INIT wrapper. see the rant at
-- the top of the file if you forgot why.

Rumble.ensure_config()
Rumble.debug_init()

-- ui definitions are safe here (they only assign fields), but the G.FUNCS
-- callbacks they point at retry below - we can be running before the game
-- has even built G.FUNCS. load order is a hateful thing
Rumble.install_ui()
Rumble.try_install_funcs()

-- update_canvas_juice may not exist yet either - it lives in the game's own
-- function files, which might not be loaded yet. 
Rumble.install_haptics()

-- installed no matter what, because it also drives the retries and the
-- debug flush. it's the dependable one.
Rumble.install_love_update()

sendDebugMessage("Rumble engine " .. tostring(Rumble.ENGINE_VERSION)
    .. " loaded (" .. Rumble.platform_label()
    .. (Rumble.IS_PROTON_WINE and (": " .. Rumble.PROTON_REASON) or "") .. ")")