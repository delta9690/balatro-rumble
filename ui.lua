-- ui.lua - the mod menu. two layout rules matter here and both were learned
-- the hard way, i.e. by me screaming at a misaligned pane for an hour:
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
--      padding the cells to match. i hate it here.

Rumble = Rumble or {}

-- row geometry. everything derives from these so every tab lines up.
local W_TOGGLE = 0.45
local W_LABEL = 1.65
local W_A = 2.4
local W_B = 1.55
local COLUMN_W = W_TOGGLE + W_LABEL + W_A + W_B + 0.24
local ROW_W = COLUMN_W

-- computed lazily. at file scope this ran during SMODS.load_file, before
-- anything guarantees G.C exists - which is a launch-time crash for every
-- user if the load order ever shifts. by the time a tab is opened, G.C is
-- unquestionably there. (i found this the fun way: a crash on boot for
-- literally everyone. cool. cool cool cool.)
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
            padding = 0.035,
            minw = ROW_W,
            minh = 0.44,
            r = 0.06,
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

local function two_column_grid(items)
    local rows = {}
    for index = 1, #items, 2 do
        local cells = {
            { n = G.UIT.C, config = { minw = COLUMN_W, align = "cm" }, nodes = { items[index] } }
        }
        if items[index + 1] then
            cells[#cells + 1] = {
                n = G.UIT.C, config = { minw = COLUMN_W, align = "cm" },
                nodes = { items[index + 1] }
            }
        end
        rows[#rows + 1] = {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.025 },
            nodes = cells
        }
    end
    return rows
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
                w = 0.45,
                scale = 0.4
            })
        }),
        text_cell(meta.label, 0.23, W_LABEL, "cl"),
        cell(W_A, "cm", {
            create_slider({
                ref_table = c,
                ref_value = cat .. "_power",
                w = 1.55,
                h = 0.3,
                min = 0,
                max = 100,
                decimal_places = 0,
                text_suffix = "%",
                text_scale = 0.2
            })
        }),
    }

    if Rumble.IS_ANDROID then
        nodes[#nodes + 1] = cell(W_B, "cm", {})
    else
        local profile_index = tonumber(c[cat .. "_motor_profile"]) or 3
        local profile_nodes = {
            create_option_cycle({
                options = Rumble.MOTOR_PROFILES,
                current_option = profile_index,
                opt_callback = "rumble_set_motor_profile_" .. cat,
                scale = 0.42,
                w = 2.05,
                h = 0.35,
                no_pips = true
            })
        }
        profile_nodes[#profile_nodes + 1] = create_toggle({
            ref_table = c,
            ref_value = cat .. "_kick",
            label = "Kick",
            w = 0.4,
            scale = 0.35,
            label_scale = 0.2
        })
        nodes[#nodes + 1] = cell(W_B, "cm", {
            { n = G.UIT.R, config = { align = "cm" }, nodes = profile_nodes }
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
            w = 1.55,
            h = 0.3,
            min = 5,
            max = 300,
            decimal_places = 0,
            text_suffix = "ms",
            text_scale = 0.2
        })
    else
        slider = create_slider({
            ref_table = c,
            ref_value = cat .. "_decay",
            w = 1.55,
            h = 0.3,
            min = 1,
            max = 40,
            decimal_places = 0,
            text_scale = 0.2
        })
    end

    return content_row({
        cell(W_TOGGLE, "cm", {
            create_toggle({
                ref_table = c,
                ref_value = cat .. "_enabled",
                label = "",
                w = 0.45,
                scale = 0.4
            })
        }),
        text_cell(meta.label, 0.23, W_LABEL, "cl"),
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

local function cycle_setting(label_text, ref_value, options, callback, current)
    return setting_row(label_text, create_option_cycle({
        ref_table = Rumble.MOD.config,
        ref_value = ref_value,
        options = options,
        current_option = current or (Rumble.MOD.config[ref_value] == "absolute" and 2 or 1),
        opt_callback = callback,
        scale = 0.65,
        w = 2.6,
        h = 0.45,
        no_pips = true
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

-- Steamodded ships SMODS.UIScrollBox + SMODS.GUI.scrollbar specifically because
-- vanilla's flexbox has NO overflow handling - a tall node just grows off the
-- screen. Wrap a stack of rows in a vertically scrolling box with a visible
-- bar so the 18 category rows don't eat the whole pane.
local function has_scrollbox()
    return type(SMODS) == "table"
        and type(SMODS.UIScrollBox) == "function"
        and type(SMODS.GUI) == "table"
        and type(SMODS.GUI.scrollbar) == "function"
end

-- header + footer are pinned OUTSIDE the scroll box; only the middle rows
-- scroll. this is what actually triggers the scrollbar: the middle content has
-- to be taller than the (small) viewport, not padded out by the header/footer
-- so the box itself just grows huge and refuses to scroll. learned the hard
-- way, obviously. (the scrollbox fought me for DAYS. we ended up paginating
-- instead. this function only survives for the Info tab now. rip.)
local function scroll_page(header_rows, middle_rows, footer_rows, maxh)
    if not has_scrollbox() then
        local all = {}
        for _, r in ipairs(header_rows) do all[#all + 1] = r end
        for _, r in ipairs(middle_rows) do all[#all + 1] = r end
        for _, r in ipairs(footer_rows) do all[#all + 1] = r end
        return page(all)
    end

    local box = SMODS.UIScrollBox({
        content = {
            definition = {
                n = G.UIT.ROOT,
                config = { align = "cm", colour = G.C.CLEAR },
                nodes = {
                    { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = middle_rows }
                }
            },
            config = { align = "cm" },
        },
        overflow = { node_config = { maxh = maxh, colour = G.C.CLEAR, no_overflow = "vh" } },
        sync_mode = "offset",
    })

    local bar = SMODS.GUI.scrollbar({
        w = 0.18,
        h = maxh,
        knob_h = math.max(0.35, maxh / 10),
        colour = G.C.RED,
        bg_colour = { 0, 0, 0, 0.15 },
        scroll_collision_obj = box,
    })

    local nodes = {}
    for _, r in ipairs(header_rows) do nodes[#nodes + 1] = r end
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
        { n = G.UIT.O, config = { object = box } },
        bar,
    } }
    for _, r in ipairs(footer_rows) do nodes[#nodes + 1] = r end

    return {
        n = G.UIT.ROOT,
        config = { align = "cm", emboss = 0.05, r = 0.1, padding = 0.12, colour = G.C.BLACK },
        nodes = {
            { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = nodes }
        },
    }
end

--------------------------------------------------
------------------ PAGED GRID ---------------------
--------------------------------------------------

-- 18 categories don't fit a fixed-height mod tab window, and the UIScrollBox
-- fights the framework (native tabs enforce a ~6-unit viewport). so we page
-- them like steamodded pages its own card collections: a shoulder-button
-- "Page X/Y" cycle rebuilds ONE stable object node. copying the proven
-- your_collection_tags_page pattern instead of reinventing scrolling.
-- (the scrollbox lost. pagination won. i'm at peace with it.)
Rumble._page_builders = Rumble._page_builders or {}

local function paged_grid_tab(cats, row_builder, header_label, footer_notes, page_key)
    local per_page = 6
    local page_count = math.max(1, math.ceil(#cats / per_page))
    local box_id = "rumble_page_" .. page_key

    local function build_rows(page)
        page = page or 1
        local items = {}
        local stop = math.min((page - 1) * per_page + 6, #cats)
        for i = (page - 1) * per_page + 1, stop do
            items[#items + 1] = row_builder(cats[i])
        end
        return two_column_grid(items)
    end

    Rumble._page_builders[page_key] = { rows = build_rows, box_id = box_id }

    local page_options = {}
    for i = 1, page_count do
        page_options[#page_options + 1] = "Page " .. i .. "/" .. page_count
    end

    -- one explicit column: header on top, paged grid in the middle, then the
    -- footer notes and page cycle at the bottom. CRITICAL gotcha from the
    -- layout engine (UIBox:calculate_xywh): a column stacks ONLY R children
    -- vertically - any O object or C child is laid out HORIZONTALLY instead.
    -- so the grid O and the page cycle must each be wrapped in an R, or they
    -- drift right/up instead of sitting below. (the old config_tab never hit
    -- this because all its children are already rows.)
    -- (this one took me an embarrassing amount of source-diving to figure out.
    -- the page button kept ending up to the RIGHT of the text. i was losing it.)
    local col_nodes = { header_row(header_label) }
    col_nodes[#col_nodes + 1] = { n = G.UIT.R, config = { align = "cm" }, nodes = {
        {
            n = G.UIT.O,
            config = {
                object = UIBox{
                    definition = { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR },
                        nodes = { { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = build_rows(1) } } },
                    config = { offset = { x = 0, y = 0 }, align = "cm" },
                },
                id = box_id,
                align = "cm",
            },
        },
    } }
    for _, note in ipairs(footer_notes) do col_nodes[#col_nodes + 1] = note end
    if page_count > 1 then
        col_nodes[#col_nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
            create_option_cycle({
                options = page_options,
                w = 3,
                cycle_shoulders = true,
                opt_callback = "rumble_page_" .. page_key,
                current_option = 1,
                no_pips = true,
                focus_args = { snap_to = true },
            })
        } }
    end

    return {
        n = G.UIT.ROOT,
        config = { align = "cm", emboss = 0.05, r = 0.1, padding = 0.12, colour = G.C.BLACK },
        nodes = {
            { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = col_nodes }
        },
    }
end

-- rebuild the paged content in place when the shoulder cycle changes.
local function register_page_callback(page_key)
    G.FUNCS["rumble_page_" .. page_key] = function(args)
        local info = Rumble._page_builders[page_key]
        if not info then return end
        local page = (args and args.cycle_config and args.cycle_config.current_option) or 1
        local e = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID(info.box_id)
        if not e or not e.UIBox then return end
        if e.config.object then e.config.object:remove() end
        e.config.object = UIBox{
            definition = { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR },
                nodes = { { n = G.UIT.C, config = { align = "cm", padding = 0.04 }, nodes = info.rows(page) } } },
            config = { offset = { x = 0, y = 0 }, align = "cm", parent = e },
        }
        e.UIBox:recalculate()
    end
end

--------------------------------------------------
------------------ TABS ---------------------------
--------------------------------------------------

local GAMEPLAY_CATS = {
    "card_draw", "coin", "cash_out", "hand_played",
    "card_score_chips", "card_score_mult", "card_score_xmult",
    "card_score_edition", "card_score_generic", "card_debuff",
    "card_destroy", "card_shatter", "money_gain", "blind_reveal",
    "startup_open", "startup_ramp", "startup_close"
}

local UI_CATS = { "ui_confirm", "ui_focus", "ui_tap" }

local function config_tab()
    Rumble.ensure_config()

    local rows = {
        slider_setting("Master Strength", "master_strength", 0, 100, "%"),
        note_row("power is the event command before master; 100% reaches master"),
    }

    if Rumble.IS_ANDROID then
        rows[#rows + 1] = note_row("Android uses duration for intensity and replaces weaker pulses")
    else
        rows[#rows + 1] = slider_setting("Heavy Hold (ms)", "heavy_hold_ms", 0, 250, "")
        rows[#rows + 1] = slider_setting("Light Hold (ms)", "light_hold_ms", 0, 250, "")
        rows[#rows + 1] = slider_setting("Kick Window (ms)", "kick_window_ms", 1, 100, "")
        rows[#rows + 1] = cycle_setting("Kick Mode", "kick_mode", { "Multiplicative", "Absolute 100%" },
            "rumble_set_kick_mode")
        rows[#rows + 1] = toggle_setting("Spinup Assist", "spinup_assist")
        rows[#rows + 1] = slider_setting("Spinup Window (ms)", "assist_window_ms", 5, 120, "")
        rows[#rows + 1] = note_row("spinup assist fires a brief 100% on the large motor to reach speed faster")
        rows[#rows + 1] = note_row("heavy motor = left channel, light motor = right channel")
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

    return paged_grid_tab(GAMEPLAY_CATS, cat_row, "Power %", {
        note_row("unchecking disables that event entirely - zero rumble, nothing passed to vanilla"),
        note_row("Kick = sharp 100% pulse for a crisp attack (see Info tab for details)"),
        note_row("title open/ramp/close = splash sequence phases; profiles route independently"),
    }, "gameplay")
end

local function ui_tab()
    Rumble.ensure_config()

    local items = {}
    for _, cat in ipairs(UI_CATS) do
        items[#items + 1] = cat_row(cat)
    end
    local rows = { header_row("Power %") }
    local compact_rows = two_column_grid(items)
    for _, row in ipairs(compact_rows) do rows[#rows + 1] = row end
    rows[#rows + 1] = note_row("confirm = bumper / tab change, focus = d-pad move, tap = plain click")

    return page(rows)
end

local function gameplay_feel_tab()
    Rumble.ensure_config()

    return paged_grid_tab(GAMEPLAY_CATS, feel_row,
        Rumble.IS_ANDROID and "Pulse (ms)" or "Decay", {
        note_row(Rumble.IS_ANDROID
            and "android has no amplitude api, so a longer pulse is the only way to feel stronger"
            or "decay = how fast the pad falls off after a hit. higher = snappier, lower = longer tail"),
    }, "gameplay_feel")
end

local function ui_feel_tab()
    Rumble.ensure_config()

    local items = {}
    for _, cat in ipairs(UI_CATS) do
        items[#items + 1] = feel_row(cat)
    end
    local rows = { header_row(Rumble.IS_ANDROID and "Pulse (ms)" or "Decay") }
    local compact_rows = two_column_grid(items)
    for _, row in ipairs(compact_rows) do rows[#rows + 1] = row end
    rows[#rows + 1] = note_row(Rumble.IS_ANDROID
        and "android has no amplitude api, so a longer pulse is the only way to feel stronger"
        or "decay = how fast the pad falls off after a hit. higher = snappier, lower = longer tail")

    return page(rows)
end

--------------------------------------------------
------------------ INFO TAB -----------------------
--------------------------------------------------

-- defines the jargon in one place so nobody has to guess at "Kick" on every
-- single row (which also built the rows out into a horizontal mess). the
-- profile list lives here too now.
local function info_tab()
    local terms = {
        { "Master", "global 0-100% scale snapped to 10% steps. every command is multiplied by it last." },
        { "Power", "a category's pre-master strength, 0-100%. 100% power alone = 100% of whatever master is." },
        { "Kick", "a sharp 100% pulse on an event's motor to make the attack crisp. light/balanced effects use this." },
        { "Spinup assist", "a brief 100% command on the large motor so it reaches speed faster. applies to heavy-primary effects." },
        { "Infill", "the small motor fills the gap while the large motor accelerates, then blends out." },
        { "Decay", "how fast a hit falls off. higher = snappier, lower = longer tail." },
    }

    local profiles = {
        { "Light", "all on the small (fast, crisp) motor. sharp ticks and texture." },
        { "Light Bias", "mostly small motor, a hint of large. still a tick with a little body." },
        { "Balanced", "large-primary with half small bleed. solid thump plus crisp edge." },
        { "Heavy Bias", "large-primary with a feather of small. weighty, minimal texture." },
        { "Heavy", "all on the large (slow, deep) motor. pure impact and body." },
        { "Dual Full", "BOTH motors at full simultaneously. the loudest setting." },
    }

    if Rumble.IS_ANDROID then
        terms = {
            { "Master", "global 0-100% scale snapped to 10% steps." },
            { "Power", "a category's strength, mapped to pulse length (android has no amplitude)." },
            { "Pulse", "duration of the vibration; longer = stronger. new pulses replace weaker ones." },
        }
        profiles = {}
    end

    local rows = {}
    for _, term in ipairs(terms) do
        rows[#rows + 1] = content_row({
            text_cell(term[1], 0.3, 2.4, "cl"),
            text_cell(term[2], 0.26, 8.4, "cl"),
        })
    end

    if #profiles > 0 then
        rows[#rows + 1] = note_row("Motor profiles:")
        for _, prof in ipairs(profiles) do
            rows[#rows + 1] = content_row({
                text_cell(prof[1], 0.3, 2.4, "cl"),
                text_cell(prof[2], 0.26, 8.4, "cl"),
            })
        end
    end

    return scroll_page({}, rows, {}, 6)
end

--------------------------------------------------
------------------ INSTALL ------------------------
--------------------------------------------------

-- closure factory so each cycle callback knows its own category. without
-- this every callback would capture the same loop variable and write the
-- wrong category's mix. (classic lua closure footgun. got me once. never again.)
local function make_motor_callback(cat)
    return function(args)
        if args and args.to_key then
            Rumble.MOD.config[cat .. "_motor_profile"] = args.to_key
        end
    end
end

-- G.FUNCS registration. retryable on purpose: we can run before the game has
-- built G.FUNCS, and create_option_cycle resolves opt_callback by indexing
-- G.FUNCS at click time - so registering late is completely fine, registering
-- never is not. returns true once it has actually landed.
function Rumble.try_install_funcs()
    if type(G) ~= "table" or type(G.FUNCS) ~= "table" then
        return false
    end

    for _, cat in ipairs(Rumble.ORDERED_CATEGORIES) do
        G.FUNCS["rumble_set_motor_profile_" .. cat] = make_motor_callback(cat)
    end
    G.FUNCS.rumble_set_kick_mode = function(args)
        if args and args.to_key then
            Rumble.MOD.config.kick_mode = args.to_key == 2 and "absolute" or "multiplicative"
        end
    end
    register_page_callback("gameplay")
    register_page_callback("gameplay_feel")

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
            { label = "Info", tab_definition_function = info_tab },
        }
    end
end