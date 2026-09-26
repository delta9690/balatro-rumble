return {
    master_strength = 100,
    desktop_hold_ms = 60,
    android_min_pulse_ms = 12,
    android_settle_ms = 50,
    debug_log = false,

    card_draw_enabled = true,    card_draw_strength = 100,
    card_draw_decay = 8,         card_draw_duration_ms = 40,
    card_draw_min_retrigger_ms = 0,    card_draw_motor_profile_index = 3,

    coin_enabled = true,         coin_strength = 100,
    coin_decay = 14,             coin_duration_ms = 25,
    coin_min_retrigger_ms = 0,         coin_motor_profile_index = 2,

    cash_out_enabled = true,     cash_out_strength = 100,
    cash_out_decay = 5,          cash_out_duration_ms = 200,
    cash_out_min_retrigger_ms = 0,     cash_out_motor_profile_index = 5,

    hand_played_enabled = true,  hand_played_strength = 100,
    hand_played_decay = 8,       hand_played_duration_ms = 100,
    hand_played_min_retrigger_ms = 0,  hand_played_motor_profile_index = 3,

    card_score_enabled = true,   card_score_strength = 100,
    card_score_decay = 14,       card_score_duration_ms = 15,
    card_score_min_retrigger_ms = 0,   card_score_motor_profile_index = 2,

    blind_reveal_enabled = true, blind_reveal_strength = 100,
    blind_reveal_decay = 6,      blind_reveal_duration_ms = 180,
    blind_reveal_min_retrigger_ms = 0, blind_reveal_motor_profile_index = 5,

    ui_confirm_enabled = true,   ui_confirm_strength = 100,
    ui_confirm_decay = 30,       ui_confirm_duration_ms = 30,
    ui_confirm_min_retrigger_ms = 100, ui_confirm_motor_profile_index = 4,

    ui_focus_enabled = true,     ui_focus_strength = 100,
    ui_focus_decay = 32,         ui_focus_duration_ms = 15,
    ui_focus_min_retrigger_ms = 100,   ui_focus_motor_profile_index = 2,

    ui_tap_enabled = true,       ui_tap_strength = 100,
    ui_tap_decay = 34,           ui_tap_duration_ms = 20,
    ui_tap_min_retrigger_ms = 80,      ui_tap_motor_profile_index = 2,

    startup_card_enabled = true, startup_card_strength = 100,
    startup_card_decay = 3,      startup_card_duration_ms = 250,
    startup_card_min_retrigger_ms = 0, startup_card_motor_profile_index = 5,
}