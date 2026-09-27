-- metadata lives in Rumble.json. two things to NOT put back in this file:
--   1. a --- STEAMODDED HEADER block (steamodded would load the mod twice)
--   2. any reference to SMODS.INIT
--
-- SMODS.INIT was removed in steamodded 1.0.0+, and it's what produced
-- "attempt to index field 'INIT' (a nil value)". the loader flags SMODS.INIT
-- as an outdated 0.9.8 pattern, and older builds papered over it with a
-- compat shim that created the table. legacy header detection triggered that
-- shim; json metadata does not. top level scope is the init now, which is
-- also what the official migration guide says to do.
--
-- extra bonus: that same outdated path wipes mod.config and skips
-- load_mod_config, so removing this also gets config loading working right.

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

-- one-time banner lines (mod identity + platform) written at the top of the
-- FIRST flush. stored behind a flag so it's present whether debug_log is on
-- at boot or toggled later, and never duplicated.
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

-- per-category getters (cat_power, cat_enabled, cat_decay, cat_duration,
-- cat_min_retrigger, cat_profile) live in categories.lua next to the actual
-- CATEGORY_DEFAULTS table. do NOT redefine them here - a previous copy
-- referenced .default_decay / .default_duration_ms / .default_min_retrigger_s,
-- keys that categories.lua renamed to .decay / .duration / (gone), and the
-- shadowed copy was a latent crash waiting for a load-order change. fight me.

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

sendDebugMessage("Rumble engine " .. tostring(Rumble.ENGINE_VERSION)
    .. " loaded (" .. Rumble.platform_label()
    .. (Rumble.IS_PROTON_WINE and (": " .. Rumble.PROTON_REASON) or "") .. ")")