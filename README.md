# Cursor+

Cursor+ is a small macOS menu bar app that keeps your Mac looking active by nudging your real mouse cursor around. Not a twitchy jiggle, actual motion: it picks a random spot, picks a speed, and follows a curved path there, with the occasional slow scroll thrown in. The second you touch your own mouse or keyboard it gets out of the way, and it only comes back once you've gone quiet for a bit. You can kill it any time by tapping Esc three times.

Out of the box it only moves and scrolls. If you want, you can also draw **click areas**, rectangles you place on screen, and it will every so often curve into one and click a spot inside it with a slow, deliberate approach. It only ever clicks inside the rectangles you draw. It never clicks random empty space, so put your rectangles on things that are actually safe to click.

One thing up front: this is a personal tool for your own machine. It synthesizes input and it listens for the Esc stop gesture, so don't run it on a work managed (MDM) Mac.

## What makes it look real

- The motion has actual variety. Each move picks a speed class, from very slow to very fast, weighted by whichever preset you chose, then a real velocity inside that range, and follows a curved path instead of a straight line.
- Moving the cursor is what resets the system idle timer, which is the entire reason this works. It can hold the display awake too if you want.
- It takes breaks like a person does, short pauses between bursts of movement, with an optional setting for the occasional longer rest so the idle pattern isn't suspiciously even.
- When you give it click areas, it heads for one, settles, and clicks a point biased toward the center, never the dead edge or empty space.
- It can tell its own movement apart from yours without tagging the events with any kind of marker. That keeps the auto pause reliable and keeps the motion clean.

## Building it

You need the Swift toolchain on macOS 14 or newer. I built and tested it on macOS 26 on Apple Silicon.

```bash
./scripts/build_app.sh
open "Cursor+.app"
```

A cursor icon shows up in your menu bar. Running `swift build` on its own only gives you the bare binary, the menu bar behavior needs the assembled `.app`. If you want the Accessibility grant to survive rebuilds instead of resetting each time, sign with a stable identity. The instructions are in the comments at the top of [`scripts/build_app.sh`](scripts/build_app.sh).

## First run and permissions

macOS will ask for permission and deep link you to the right pane:

**System Settings, Privacy and Security, Accessibility**, then turn on **Cursor+**.

That one grant covers moving the cursor, scrolling, and watching for your input. If the menu says it needs permission or that the kill switch is unavailable, finish the grant and relaunch.

## Using it

Click the menu bar icon:

- **Start and Stop** turn it on and off. Stop is always a reliable kill.
- **Motion speed**: Calm, Balanced, Lively, Wild.
- **Wander interval**: 10 to 20s, 20 to 40s, 30 to 60s, or 60 to 120s. This is how long it roams before resting.
- **Occasional scrolling** lets it emit a rare slow scroll, the kind a trackpad makes.
- **Human idle pauses** drop short, natural pauses between bursts.
- **Occasional long pauses** is off by default. Turn it on and it will rarely take a 30 to 90 second break for a more human idle pattern. Heads up: during a long pause the Mac can read as "away" to presence based status, even though the display stays awake.
- **Click defined areas** toggles whether it clicks inside your zones at all.
- **Add or Edit click area** opens the overlay editor. Drag to add a rectangle, click to select one, drag the handles to resize, Delete to remove it, Esc or Return when you're done.
- **Clear click areas** removes all of them.
- **Prevent display sleep** also holds the screen awake.

To stop at any time, tap Esc three times, or click Stop.

## How it stays out of trouble

- It only clicks inside the areas you define, never random or empty space. With no areas set it just moves and scrolls.
- It auto pauses the instant you use the mouse or keyboard, and comes back once you've gone idle.
- It freezes while a password field or the lock screen is focused, so the Esc kill gesture is never in doubt.
- The triple Esc kill switch runs on its own self healing global tap with a backup monitor, and it's kept completely separate from the motion engine. Cursor+ never synthesizes key events, so nothing it does can interfere with the stop.

## How it's put together

| File | What it does |
|---|---|
| `Sources/CursorPlus/InputEngine.swift` | posts the real cursor moves and scrolls with CGEvent, with hardware consistent deltas |
| `Sources/CursorPlus/MovementEngine.swift` | speed classes, velocity sampling, the curved paths and the tremor, plus the scroll player |
| `Sources/CursorPlus/Geometry.swift` | the coordinate math between AppKit and CG space across every display |
| `Sources/CursorPlus/StateMachine.swift` | the rhythm: wander, maybe scroll, maybe visit a click zone, rest, repeat |
| `Sources/CursorPlus/AutoPause.swift`, `SyntheticInputLog.swift` | hands control back the moment you touch input, and tells its own motion from yours |
| `Sources/CursorPlus/KillSwitch.swift` | the self healing global tap behind the triple Esc stop |
| `Sources/CursorPlus/ClickZone.swift`, `ClickZoneEditor.swift` | the click areas and the full screen editor for drawing them |
| `Sources/CursorPlus/AppController.swift`, `MenuBarController.swift`, `Permissions.swift`, `Settings.swift` | control, the menu, the privacy grants, and the saved settings |

## License

[MIT](LICENSE). Copyright 2026 Ahmed Ufuk Serce.

Personal tool. Whatever you do with it is on you, including running it somewhere it's actually allowed.
