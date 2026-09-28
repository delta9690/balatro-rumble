Rumble = Rumble or {}

Rumble.ENGINE_VERSION = "5.1"
Rumble.ORDERED_CATEGORIES = {
    "card_draw", "coin", "cash_out", "hand_played",
    "card_score_chips", "card_score_mult", "card_score_xmult",
    "card_score_edition", "card_score_generic", "card_debuff",
    "card_destroy", "card_shatter", "money_gain", "blind_reveal",
    "startup_open", "startup_ramp", "startup_close",
    "ui_tap", "ui_confirm", "ui_focus"
}

Rumble.MOTOR_PROFILES = { "Light", "Light Bias", "Balanced", "Heavy Bias", "Heavy", "Dual Full" }
Rumble.CATEGORY_DEFAULTS = {
    card_draw = { label = "Card Draw", power = 55, profile = 3, decay = 8, duration = 40 },
    coin = { label = "Coin Pickup", power = 35, profile = 2, decay = 14, duration = 25 },
    cash_out = { label = "Cash Out", power = 90, profile = 5, decay = 5, duration = 200 },
    hand_played = { label = "Hand Played", power = 45, profile = 3, decay = 8, duration = 100 },
    card_score_chips = { label = "Score Chips", power = 18, profile = 2, decay = 14, duration = 15 },
    card_score_mult = { label = "Score Mult", power = 24, profile = 2, decay = 14, duration = 15 },
    card_score_xmult = { label = "Score XMult", power = 38, profile = 3, decay = 12, duration = 20 },
    card_score_edition = { label = "Score Edition", power = 28, profile = 2, decay = 14, duration = 18 },
    card_score_generic = { label = "Score", power = 15, profile = 2, decay = 14, duration = 15 },
    card_debuff = { label = "Card Debuff", power = 25, profile = 1, decay = 16, duration = 20 },
    card_destroy = { label = "Card Destroy", power = 50, profile = 4, decay = 8, duration = 60 },
    card_shatter = { label = "Card Shatter", power = 65, profile = 5, decay = 7, duration = 70 },
    money_gain = { label = "Money Gain", power = 20, profile = 2, decay = 18, duration = 20 },
    blind_reveal = { label = "Blind Reveal", power = 60, profile = 5, decay = 6, duration = 180 },
    startup_open = { label = "Title Open", power = 40, profile = 5, decay = 3, duration = 120 },
    startup_ramp = { label = "Title Ramp", power = 25, profile = 3, decay = 8, duration = 30 },
    startup_close = { label = "Title Close", power = 85, profile = 5, decay = 3, duration = 250 },
    ui_tap = { label = "Menu Tap", power = 35, profile = 2, decay = 34, duration = 20 },
    ui_confirm = { label = "Confirm", power = 70, profile = 4, decay = 30, duration = 30 },
    ui_focus = { label = "Focus Move", power = 70, profile = 2, decay = 22, duration = 22 }
}

Rumble.SOUND_MAP = {
    card1 = "card_draw", coin6 = "cash_out", coin7 = "cash_out", cardFan2 = "hand_played",
    chips1 = "card_score_chips", multhit1 = "card_score_mult", multhit2 = "card_score_xmult",
    foil2 = "card_score_edition", generic1 = "card_score_generic", cancel = "card_debuff",
    explosion_release1 = "card_destroy", coin1 = "money_gain",
    introPad1 = "startup_open", magic_crumple2 = "startup_close",
    magic_crumple3 = "startup_close"
}

-- NOTE: profile order must match MOTOR_PROFILES above, or the UI's option
-- cycle and this lookup disagree and everything routes to the wrong motor.
-- No, I will not write a test for this. Just don't reorder either table.
local PROFILE_BLEED = {
    [1] = { 0,   1    }, -- Light      -> all light, heavy never even spins
    [2] = { 0.28, 1    }, -- Light Bias -> mostly light, hint of heavy
    [3] = { 1,    0.50 }, -- Balanced   -> heavy primary, light half-bleed
    [4] = { 1,    0.28 }, -- Heavy Bias -> heavy primary, light feather
    [5] = { 1,    0    }, -- Heavy      -> all heavy, light never even spins
    [6] = { 1,    1    }, -- Dual Full  -> BOTH at full, because why not live a little
}

-- returns heavy_bleed, light_bleed (fractions of the contribution each motor
-- gets BEFORE floors / fallback / supplement do their own weird thing).
local function profile(index)
    index = math.max(1, math.min(6, math.floor((tonumber(index) or 3) + 0.5)))
    local b = PROFILE_BLEED[index]
    return b[1], b[2]
end

function Rumble.cat_profile(cat)
    return profile(Rumble.MOD.config[cat .. "_motor_profile"])
end

-- Safe metadata lookup. Every getter indexes CATEGORY_DEFAULTS[cat], which
-- NASTILY crashes (sorry) on an unknown category - things like a placeholder
-- "(none)" or a future category that hasn't been added to the table yet. this
-- returns a sane fallback instead of a nil index, so a bad cat degrades to
-- "a faint, safe tick" rather than taking the whole frame down.
local CATEGORY_FALLBACK = { label = "Unknown", power = 20, profile = 3, decay = 10, duration = 30 }

local function cat_meta(cat)
    return Rumble.CATEGORY_DEFAULTS[cat] or CATEGORY_FALLBACK
end

function Rumble.cat_power(cat)
    local value = tonumber(Rumble.MOD.config[cat .. "_power"])
        or cat_meta(cat).power
    return math.max(0, math.min(100, value)) / 100
end

function Rumble.cat_enabled(cat)
    return Rumble.MOD.config[cat .. "_enabled"] ~= false
end

function Rumble.cat_decay(cat)
    return math.max(1, tonumber(Rumble.MOD.config[cat .. "_decay"])
        or cat_meta(cat).decay)
end

function Rumble.cat_duration(cat)
    return math.max(0.001, tonumber(Rumble.MOD.config[cat .. "_duration_ms"])
        or cat_meta(cat).duration) / 1000
end

function Rumble.cat_min_retrigger(cat)
    return math.max(0, tonumber(Rumble.MOD.config[cat .. "_min_retrigger_ms"]) or 0) / 1000
end

function Rumble.sound_category(name)
    if type(name) ~= "string" then return nil end
    if name:match("^glass[1-6]$") then return "card_shatter" end
    return Rumble.SOUND_MAP[name]
end
