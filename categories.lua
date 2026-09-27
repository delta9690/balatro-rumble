-- categories.lua
-- the catalogue of haptic events and the numbers that map to them. vanilla
-- does zero tagging - six call sites add hardcoded constants to G.VIBRATION
-- and G.ROOM.jiggle and that is the entire api. we fingerprint them here.

Rumble = Rumble or {}

Rumble.ORDERED_CATEGORIES = {
    "card_draw", "coin", "cash_out",
    "hand_played", "card_score", "blind_reveal",
    "card_destroy",
    "ui_confirm", "ui_focus", "ui_tap",
    "startup_card"
}

-- motor mix presets, stored by numeric index in config. 1 = all light, 5 = all heavy.

Rumble.MOTOR_PROFILES = { "Light", "Light Bias", "Balanced", "Heavy Bias", "Heavy" }
Rumble.MOTOR_PROFILE_HEAVY = { 0.00, 0.25, 0.50, 0.75, 1.00 }

Rumble.CATEGORY_DEFAULTS = {
    card_draw    = { label = "Card Draw",    base_weight = 0.60, default_motor_profile = 3, default_decay = 8,  default_duration_ms = 40,  default_min_retrigger_s = 0 },
    coin         = { label = "Coin Pickup",  base_weight = 0.40, default_motor_profile = 2, default_decay = 14, default_duration_ms = 25,  default_min_retrigger_s = 0 },
    cash_out     = { label = "Cash Out",     base_weight = 1.00, default_motor_profile = 5, default_decay = 5,  default_duration_ms = 200, default_min_retrigger_s = 0 },
    hand_played  = { label = "Hand Played",  base_weight = 0.40, default_motor_profile = 3, default_decay = 8,  default_duration_ms = 100, default_min_retrigger_s = 0 },
    card_score   = { label = "Card Scoring", base_weight = 0.14, default_motor_profile = 2, default_decay = 14, default_duration_ms = 15,  default_min_retrigger_s = 0 },
    blind_reveal = { label = "Blind Reveal", base_weight = 0.60, default_motor_profile = 5, default_decay = 6,  default_duration_ms = 180, default_min_retrigger_s = 0 },

    -- card.lua Card:start_dissolve / Card:shatter, paired with
    -- play_sound('explosion_release1'). these fire from delay-less
    -- E_MANAGER events, so N destroyed cards land in ONE frame. it's a
    -- texture event rather than a payoff, so the weight stays modest and it
    -- falls off fast.
    card_destroy = { label = "Card Destroyed", base_weight = 0.30, default_motor_profile = 4, default_decay = 18, default_duration_ms = 35, default_min_retrigger_s = 0 },

    ui_confirm   = { label = "Confirm",      base_weight = 0.90, default_motor_profile = 4, default_decay = 30, default_duration_ms = 30,  default_min_retrigger_s = 0.10 },
    ui_focus     = { label = "Focus Move",   base_weight = 0.75, default_motor_profile = 2, default_decay = 32, default_duration_ms = 15,  default_min_retrigger_s = 0.10 },
    ui_tap       = { label = "Menu Tap",     base_weight = 0.50, default_motor_profile = 2, default_decay = 34, default_duration_ms = 20,  default_min_retrigger_s = 0.08 },

    startup_card = { label = "Title Card",   base_weight = 1.00, default_motor_profile = 5, default_decay = 3,  default_duration_ms = 250, default_min_retrigger_s = 0 },
}

local function clamp_profile_index(v)
    v = tonumber(v) or 3
    return math.max(1, math.min(#Rumble.MOTOR_PROFILES, math.floor(v + 0.5)))
end

function Rumble.cat_motor_index(cat)
    local c = Rumble.MOD.config or {}
    local v = c[cat .. "_motor_profile_index"]

    if type(v) == "number" then
        return clamp_profile_index(v)
    end

    local legacy = c[cat .. "_heavy"]
    if type(legacy) == "number" then
        return clamp_profile_index(math.floor(legacy / 25 + 0.5) + 1)
    end

    return clamp_profile_index(Rumble.CATEGORY_DEFAULTS[cat].default_motor_profile or 3)
end

function Rumble.cat_heavy_frac(cat)
    return Rumble.MOTOR_PROFILE_HEAVY[Rumble.cat_motor_index(cat)]
end

--------------------------------------------------
------------------ CLASSIFIER ------------------
--------------------------------------------------

-- raw magnitudes straight from the decompiled source:
--   G.VIBRATION += 0.6  draw_card (delayed event)
--   G.VIBRATION += 0.4  coin (delayed, stacks)
--   G.VIBRATION += 1.0  cash_out / startup-card close / one destroyed card
--   G.VIBRATION += 0.7  focus move (d-pad/stick)
--   G.VIBRATION += 1.0  controller confirm (captured; handled upstream)
--   G.VIBRATION += 2.0  startup-card open
--   G.VIBRATION += 0.1  startup-card ramp tick
--   G.ROOM.jiggle += 0.7  card scoring pop
--   G.ROOM.jiggle += 2.0  hand played banner
--   G.ROOM.jiggle += 3.0  blind reveal
--   G.ROOM.jiggle += 0.5  every button click
--   G.ROOM.jiggle += 1.0  overlay open / tab change
--
-- card_destroy, the confirm, and the clicks are all subtracted UPSTREAM in
-- haptics.lua before anything reaches these classifiers. so by the time a
-- number gets here it's gameplay only, and the ambiguous 1.0s are gone.

local VIB_EPS = 0.03
local JIG_EPS = 0.06

-- the splash's +2 is numerically identical to five coins, and two destroyed
-- cards also add up to 2. you cannot shatter a glass card outside a run, so
-- the title-card reading is gated on not being in one. in a run, 2.0 falls
-- through to the coin bucket, which is the correct gameplay answer.
local function startup_plausible()
    if not G or not G.STAGE then
        return false
    end
    if G.STAGES and G.STAGE == G.STAGES.RUN then
        return false
    end
    return true
end

function Rumble.classify_vibration_delta(delta)
    if math.abs(delta - 0.6) < VIB_EPS then
        return "card_draw", 1
    elseif math.abs(delta - 1.0) < VIB_EPS then
        return "cash_out", 1
    elseif math.abs(delta - 0.7) < VIB_EPS then
        return "ui_focus", 1
    elseif math.abs(delta - 0.1) < VIB_EPS then
        return "startup_card", 1, "ramp"
    elseif math.abs(delta - 2.0) < VIB_EPS and startup_plausible() then
        return "startup_card", 1, "open"
    end

    if delta >= 0.4 - VIB_EPS then
        local n = math.max(1, math.floor(delta / 0.4 + 0.5))
        if math.abs(delta - n * 0.4) < VIB_EPS * n then
            return "coin", n
        end
    end

    return nil, 0
end

-- jiggle tolerance is tight now on purpose. haptics.lua's dt correction
-- exactly reverses vanilla's (1-5*dt) decay, so there's no contamination
-- left to absorb. the old 0.20-wide bands made 2.1 read as hand_played and
-- 2.9 read as blind_reveal - 3x and 4x too loud, mid scoring cascade, which
-- is precisely when someone would notice.
--
-- scores stack as 0.7n and are matched at exact multiples, so 2.1 is three
-- pops and 2.0 is the hand banner with no overlap between them.
function Rumble.classify_jiggle_delta(delta)
    if delta < 0.1 then
        return nil, 0
    end

    if math.abs(delta - 3.0) < JIG_EPS then
        return "blind_reveal", 1
    end

    if math.abs(delta - 2.0) < JIG_EPS then
        return "hand_played", 1
    end

    -- vanilla button click and overlay jiggle. UI bookkeeping, not events.
    if math.abs(delta - 0.5) < 0.08 then
        return nil, 0
    end

    if math.abs(delta - 1.0) < 0.08 then
        return nil, 0
    end

    if delta >= 0.7 - JIG_EPS then
        local n = math.max(1, math.floor(delta / 0.7 + 0.5))
        if math.abs(delta - n * 0.7) < JIG_EPS * n then
            return "card_score", n
        end
    end

    return nil, 0
end