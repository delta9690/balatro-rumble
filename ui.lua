-- ui.lua - the mod menu. two layout rules matter here and both were learned
-- the hard way:
--
--   1. a tab definition must return G.UIT.ROOT with align = "cm". returning
--      a bare C only works for handy, because handy overrides
--      create_UIBox_mods and draws its own UIBox - it never goes through
--      steamodded's tab renderer. without align, content gets shoved into a
--      corner of an oversized pane.
--
--   2. there is no flexbox in this engine. no width:100%, no space-between.
--      a node sizes itself to its children, and minw only stretches the BOX.
--      so "use the width" means giving every row the same explicit minw and
--      padding the cells to match.

Rumble = Rumble or {}

-- row geometry. everything derives from these so every tab lines up.
local W_TOGGLE = 0.9
local W_LABEL = 4.3
local W_A = 3.6
local W_B = 3.4
local ROW_W = W_TOGGLE + W_LABEL + W_A + W_B

local ROW_BG_CACHE
local function row_bg()
    if not ROW_BG_CACHE then
        ROW_BG_CACHE = lighten(G.C.BLACK, 0.12)
    end
    return ROW_BG_CACHE
end

--------------------------------------------------
------------------ ROW HELPERS --------------------
--------------------------------------------------

local function cell(w, align, nodes)
    return { n = G.UIT.C, config = { minw = w, align = align or "cm" }, nodes = nodes }
end

local function text_cell(str, scale, w, align)
    return cell(w, align or "cm", {
        { n = G.UIT.T, config = {
            text = str,
            scale = scale or 0.3,
            colour = G.C.UI.TEXT_LIGHT,
            shadow = true
        }}
    })
end

-- every content row goes through this so they all share one width and the
-- same subtle background.
local function content_row(nodes)
    return {
        n = G.UIT.R,
        config = {
            align = "cm",
            padding = 0.06,
            minw = ROW_W,
            minh = 0.55,
            r = 0.1,
            colour = row_bg(),
            emboss = 0.05
        },
        nodes = nodes
    }
end

local function header_row(third_label)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.04, minw = ROW_W },
        nodes = {
            text_cell("On", 0.24, W_TOGGLE),
            text_cell("Event", 0.24, W_LABEL, "cl"),
            text_cell(third_label, 0.24, W_A),
            text_cell(Rumble.IS_ANDROID and "" or "Motor Mix", 0.24, W_B),
        }
    }
end

local function note_row(str)
    return {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.07, minw = ROW_W },
        nodes = {
            { n = G.UIT.T, config = { text = str, scale = 0.24, colour = G.C.UI.TEXT_LIGHT } }
        }
    }
end

--------------------------------------------------
------------------ ROW BUILDERS -------------------
--------------------------------------------------

local function cat_row(cat)
    local meta = Rumble.CATEGORY_DEFAULTS[cat]
    local c = Rumble.MOD.config

    local nodes = {
        cell(W_TOGGLE, "cm", {
            create_toggle({
                ref_table = c,
                ref_value = cat .. "_enabled",
                label = "",
                w = 0.7,
                scale = 0.55
            })
        }),
        text_cell(meta.label, 0.3, W_LABEL, "cl"),
        cell(W_A, "cm", {
            create_slider({
                ref_table = c,
                ref_value = cat .. "_strength",
                w = 3.0,
                h = 0.4,
                min = 0,
                max = 200,
                decimal_places = 0,
                text_suffix = "%"
            })
        }),
    }

    if Rumble.IS_ANDROID then
        nodes[#nodes + 1] = cell(W_B, "cm", {})
    else
        nodes[#nodes + 1] = cell(W_B, "cm", {
            create_option_cycle({
                options = Rumble.MOTOR_PROFILES,
                current_option = Rumble.cat_motor_index(cat),
                opt_callback = "rumble_set_motor_profile_" .. cat,
                scale = 0.7,
                w = 2.6,
                h = 0.5
            })
        })
    end

    return content_row(nodes)
end

local function feel_row(cat)
    local meta = Rumble.CATEGORY_DEFAULTS[cat]
    local c = Rumble.MOD.config

    local slider
    if Rumble.IS_ANDROID then
        slider = create_slider({
            ref_table = c,
            ref_value = cat .. "_duration_ms",
            w = 3.0,
            h = 0.4,
            min = 5,
            max = 300,
            decimal_places = 0,
            text_suffix = "ms"
        })
    else
        slider = create_slider({
            ref_table = c,
            ref_value = cat .. "_decay",
            w = 3.0,
            h = 0.4,
            min = 1,
            max = 40,
            decimal_places = 0
        })
    end

    return content_row({
        cell(W_TOGGLE, "cm", {
            create_toggle({
                ref_table = c,
                ref_value = cat .. "_enabled",
                label = "",
                w = 0.7,
                scale = 0.55
            })
        }),
        text_cell(meta.label, 0.3, W_LABEL, "cl"),
        cell(W_A, "cm", { slider }),
        cell(W_B, "cm", {}),
    })
end

local function setting_row(label_text, widget)
    return content_row({
        text_cell(label_text, 0.3, W_TOGGLE + W_LABEL, "cl"),
        cell(W_A + W_B, "cm", { widget }),
    })
end

local function slider_setting(label_text, ref_value, min, max, suffix)
    return setting_row(label_text, create_slider({
        ref_table = Rumble.MOD.config,
        ref_value = ref_value,
        w = 3.0,
        h = 0.4,
        min = min,
        max = max,
        decimal_places = 0,
        text_suffix = suffix or ""
    }))
end

local function toggle_setting(label_text, ref_value)
    return setting_row(label_text, create_toggle({
        ref_table = Rumble.MOD.config,
        ref_value = ref_value,
        label = "",
        w = 0.8,
        scale = 0.6
    }))
end

--------------------------------------------------
------------------ PAGE WRAPPER -------------------
--------------------------------------------------

local function page(rows)
    return {
        n = G.UIT.ROOT,
        config = { align = "cm", emboss = 0.05, r = 0.1, padding = 0.12, colour = G.C.BLACK },
        nodes = {
            { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = rows }
        }
    }
end

--------------------------------------------------
------------------ TABS ---------------------------
--------------------------------------------------

local GAMEPLAY_CATS = {
    "card_draw", "coin", "cash_out", "hand_played",
    "card_score", "blind_reveal", "card_destroy", "startup_card"
}

local UI_CATS = { "ui_confirm", "ui_focus", "ui_tap" }

local function config_tab()
    Rumble.ensure_config()

    local rows = {
        slider_setting("Master Strength", "master_strength", 0, 100, "%"),
        note_row("master multiplies every event below, and snaps to 10% steps"),
    }

    if Rumble.IS_ANDROID then
        rows[#rows + 1] = slider_setting("Min Pulse (ms)", "android_min_pulse_ms", 5, 50, "")
        rows[#rows + 1] = slider_setting("Settle Gap (ms)", "android_settle_ms", 10, 150, "")
        rows[#rows + 1] = note_row("min pulse: raise if light taps never register")
        rows[#rows + 1] = note_row("settle gap: raise if the motor stutters between pulses")
    else
        rows[#rows + 1] = slider_setting("Attack Hold (ms)", "desktop_hold_ms", 0, 250, "")
        rows[#rows + 1] = slider_setting("Heavy Stall Floor", "heavy_stall_floor", 0, 40, "%")
        rows[#rows + 1] = toggle_setting("Heavy Gate", "heavy_gate")
        rows[#rows + 1] = note_row("below the stall floor the heavy motor just twitches, so that energy is diverted to the light motor")
    end

    rows[#rows + 1] = toggle_setting("Debug Log", "debug_log")
    rows[#rows + 1] = note_row("platform: " .. Rumble.platform_label())

    if Rumble.IS_PROTON_WINE then
        rows[#rows + 1] = note_row("wine/proton detected: " .. Rumble.PROTON_REASON)
    end

    return page(rows)
end

local function gameplay_tab()
    Rumble.ensure_config()

    local rows = { header_row("Strength %") }
    for _, cat in ipairs(GAMEPLAY_CATS) do
        rows[#rows + 1] = cat_row(cat)
    end
    rows[#rows + 1] = note_row("unchecking disables that event entirely")
    rows[#rows + 1] = note_row("strength 100% = default, 200% = doubled. mix: heavy (left) vs light (right) motor")

    return page(rows)
end

local function ui_tab()
    Rumble.ensure_config()

    local rows = { header_row("Strength %") }
    for _, cat in ipairs(UI_CATS) do
        rows[#rows + 1] = cat_row(cat)
    end
    rows[#rows + 1] = note_row("confirm = bumper / tab change, focus = d-pad move, tap = plain click")

    return page(rows)
end

local function gameplay_feel_tab()
    Rumble.ensure_config()

    local rows = { header_row(Rumble.IS_ANDROID and "Pulse (ms)" or "Decay") }
    for _, cat in ipairs(GAMEPLAY_CATS) do
        rows[#rows + 1] = feel_row(cat)
    end
    rows[#rows + 1] = note_row(Rumble.IS_ANDROID
        and "android has no amplitude api, so a longer pulse is the only way to feel stronger"
        or "decay = how fast the rumble falls off. higher = snappier, lower = longer tail")

    return page(rows)
end

local function ui_feel_tab()
    Rumble.ensure_config()

    local rows = { header_row(Rumble.IS_ANDROID and "Pulse (ms)" or "Decay") }
    for _, cat in ipairs(UI_CATS) do
        rows[#rows + 1] = feel_row(cat)
    end
    rows[#rows + 1] = note_row(Rumble.IS_ANDROID
        and "android has no amplitude api, so a longer pulse is the only way to feel stronger"
        or "decay = how fast the rumble falls off. higher = snappier, lower = longer tail")

    return page(rows)
end

--------------------------------------------------
------------------ INSTALL ------------------------
--------------------------------------------------

-- closure factory so each cycle callback knows its own category. without
-- this every callback would capture the same loop variable and write the
-- wrong category's mix.
local function make_motor_callback(cat)
    return function(args)
        if args and args.to_key then
            Rumble.MOD.config[cat .. "_motor_profile_index"] = args.to_key
        end
    end
end

-- G.FUNCS registration. retryable on purpose: we can run before the game has
-- built G.FUNCS, and create_option_cycle resolves opt_callback by indexing
-- G.FUNCS at click time - so registering late is completely fine, registering
-- never is not. returns true once it has actually landed.
function Rumble.try_install_funcs()
    if Rumble.funcs_installed then
        return true
    end

    if type(G) ~= "table" or type(G.FUNCS) ~= "table" then
        return false
    end

    for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
        G.FUNCS["rumble_set_motor_profile_" .. cat] = make_motor_callback(cat)
    end

    Rumble.funcs_installed = true
    return true
end

function Rumble.install_ui()
    if Rumble.ui_installed then
        return
    end

    Rumble.ui_installed = true

    Rumble.MOD.config_tab = function()
        return config_tab()
    end

    Rumble.MOD.extra_tabs = function()
        Rumble.ensure_config()

        return {
            { label = "Gameplay", tab_definition_function = gameplay_tab },
            { label = "UI", tab_definition_function = ui_tab },
            { label = "Gameplay Feel", tab_definition_function = gameplay_feel_tab },
            { label = "UI Feel", tab_definition_function = ui_feel_tab },
        }
    end
end