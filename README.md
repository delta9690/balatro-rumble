# Rumble

A configurable haptic engine for Balatro. Rumble replaces the game's single
vibration with a per-event system: every haptic source  -  card draws, coins,
cash out, hand played, scoring, blind reveal, menu navigation, the title
sequence  -  gets its own strength, decay, and heavy/light motor mix, all
tunable from an in-game menu.

## Requirements

- [Steamodded](https://docs.smods.dev/)
- [Lovely](https://github.com/ethangreen-dev/lovely-injector)

## Install

1. Install Steamodded and Lovely (see above).
2. Drop the `Rumble` folder into your Balatro `Mods` directory.
3. Launch the game and enable the mod from the mods menu.
4. In Balatro's settings, enable **Controller Rumble**. Rumble exposes this
  setting by enabling Balatro's rumble capability; the mod follows this
  checkbox, so vibration stays off while it is unchecked.

## Planned features

- **Total UI overhaul**  -  a cleaner, more navigable menu for the growing
  number of per-event controls, as well as further categorization.
- **Profile handling**  -  richer motor-mix profiles and easier per-event
  assignment.
- **Flame effect support**  -  a score-vs-blind intensity layer that ramps
  rumble as a run heats up.
- **Further controller tuning**  -  current defaults are mostly vibes based and may not have good response

## Why it exists

Balatro's built-in vibration is, to put it kindly, basic. The game keeps a
single `G.VIBRATION` value and forwards it to the gamepad, but only on
platforms that actually set it. Consoles and iOS set it to a non-zero value,
so their controllers do rumble. Everywhere else  -  desktop, Android  -  the
value is simply zeroed out, which leaves the game's controller-vibration code
vestigial: it is still there, it just never does anything.

The platform setting is `G.F_RUMBLE`. When it is non-zero, Balatro uses it as
a multiplier on the vibration sent to both motors; the base game also scales
that signal by `0.4`. For example, the game source sets the multiplier to
`0.7` on Switch, `0.5` on PlayStation, and `1.0` on Xbox. On desktop it is
normally unset, so the game's rumble checkbox is hidden and the normal
controller-vibration call is effectively inactive. Setting this capability
to a non-zero value makes that call work on PC too  -  but then it is still
only the base game's single envelope, with its built-in impulse and decay.
Rumble supplies the missing per-event routing and timing instead. It also
sets the capability so the **Controller Rumble** checkbox is available; that
checkbox must be enabled for Rumble to run.

Rumble exists to fill this gap. It rebuilds vibration from the ground up as a
per-event engine, so the same game events that would have driven a console
rumble now drive a proper, tunable one on desktop and Android too.

## How it works

Balatro drives vibration through a single `G.VIBRATION` value, which the game
sets each frame and decays on its own. Rumble intercepts this path and
replaces it with a two-motor model: the **heavy** (large, slow) motor and the
**light** (small, crisp) motor, each with its own attack → hold → decay
envelope.

The so-called "juice" function is worth a word of explanation. Balatro's
`update_canvas_juice` runs once per frame and is responsible for the game's
feel  -  the screen shake, the scaling, and the vibration. It reads
`G.VIBRATION` and forwards it to the gamepad. Rumble hooks exactly this
function, so it can run its own engine in the same place the game would
normally apply vibration, and it calls the original with rumble muted so the
two never double up.

The flow is as follows:

1. **Observe**  -  a `play_sound` hook records named sound events *before*
   vanilla's mute early-return, so muted sounds still fire haptics.
2. **Classify**  -  sounds map to categories (coin, cash out, card draw, and so
   on); menu focus/confirm/tap come from controller and UI hooks.
3. **Frame**  -  the hooked juice function runs the engine each frame.
4. **Synthesize**  -  the desktop engine routes each event through its motor
   profile, applies spinup assist, tap kick, and infill, and writes the final
   heavy/light command to the gamepad.

On Android the story is simpler: there is no amplitude API, so a single motor
is driven by pulse length instead  -  a stronger event simply buzzes longer.

If anything goes wrong, Rumble **locks out back to vanilla**: after a few
consecutive frame errors it disables itself, restores the original juice
function, and hands vibration back to the game untouched.

## Debug log

When **Debug Log** is enabled in the menu, Rumble writes `rumble_debug.log`
to Balatro's save directory (above your mods folder, the same place your
profile lives), rotating to `rumble_debug_old.log` once it passes 16 MB.
Lines are buffered and flushed every couple of seconds.

Each line is `[timestamp] TAG ...`. The tags:

| Tag | Meaning |
| --- | --- |
| `EVENT SOUND` | a sound mapped to a category |
| `FRAME` | per-frame input vibration and event count |
| `CONTROLLER` | a button/key press the controller hook saw |
| `desktop DISPATCH` | an event entering the desktop engine (power, profile, smooth) |
| `desktop ASSEMBLY` | the final per-frame command, with `duty_ok` (large-motor floor), assist, infill, and tap kick |
| `desktop WRITE` | the exact heavy/light values sent to the gamepad |
| `android PULSE` / `android SUPPRESS` | Android single-motor pulse or a suppressed weaker pulse |
| `ANOMALY` | a caught error or unexpected state |
| `FAILOVER VANILLA` | the engine gave up and returned control to vanilla |

The header at the top of each log records the mod name, version, author,
engine version, OS, and active backend (desktop dual-motor vs. Android
single-motor).
