# AcidFlow

GPU-rendered psychedelic flow screensaver. v3 (1.3) replaces the Mystify lines with thin soap bubbles: they
well up out of the picture, rise slowly with a glass lens, an iridescent rim and one highlight, then fade or pop. The rim
bleeds into the fluid, so the flow carries ghost rings away and a pop leaves a burst behind. The lines are still there
behind `mystify.enabled` and the M key. Since 1.3.1 the eruptions below are off by default too (`eruptions.enabled`).
v2 added eruptions: inverted drops, a soft dimple that sinks into the
picture and then a kaleidoscopic bloom welling up out of it, plus rare whole-screen "breakthroughs" where the picture folds in on itself. One self-contained HTML file (`AcidFlow.html`) plus a
Windows `.scr` host that wraps it in WebView2.

## Files

| File | Purpose |
|---|---|
| `AcidFlow.html` | The screensaver itself. Open in any browser, click for fullscreen. |
| `AcidFlow.scr` | Windows screensaver host (x64, .NET Framework 4.8 + WebView2 Runtime). Self-contained: extracts what it needs to `%LOCALAPPDATA%\AcidFlow\bin-<version>` on first run. |
| `settings.json` | Documented settings template. The host writes it to `%LOCALAPPDATA%\AcidFlow\settings.json` on first run. |
| `Install-AcidFlow.ps1` | Per-user install/uninstall, no admin needed. `-WhatIf` supported. |
| `src\AcidFlowSaver.cs` | Host source. `build.ps1` (csc.exe from .NET Framework) or `build.sh` (Mono mcs). |
| `src\lib\` | WebView2 SDK assemblies (1.0.x, net462) + native loader, embedded at build time. |

## Install

```powershell
.\Install-AcidFlow.ps1 -TimeoutSeconds 600
```

Then Settings > Personalization > Lock screen > Screen saver settings shows AcidFlow. `Settings...` opens the
FPS/quality dialog (also: `AcidFlow.scr /c`). Uninstall with `.\Install-AcidFlow.ps1 -Uninstall`.

## Settings

Everything is in `%LOCALAPPDATA%\AcidFlow\settings.json` (open it via the Windows screen saver dialog >
Settings... > "Edit settings...", or `AcidFlow.scr /c`). Comments and trailing commas are allowed; a broken file
falls back to the defaults and the reason is logged on the page console. Changes apply on the next start.

| Key | Default | Effect |
|---|---|---|
| `fps` | 30 | Frame rate cap, 10-60. Main CPU/GPU lever. |
| `quality` | 0.75 | Max render resolution as a fraction of the screen (0.35-1). Adapts downward automatically. |
| `speed` | 1.0 | Global time multiplier. |
| `flow`, `swirl`, `detail`, `warp` | 1.0 | Multipliers for fluid motion, rotation, feature size, folding. |
| `colorShift`, `saturation`, `brightness`, `vignette` | 1.0 | Colour grading. |
| `paletteSeconds`, `morphSeconds` | 150, 40 | Palette dwell time and cross-fade. |
| `palettes` | `[]` (all) | Names of built-ins and/or `{ "name": "...", "colors": ["#hex", ...] }` objects. |
| `bubbles.*` | see file | Soap bubbles (v3): `count`, `everySeconds`, `size`, `life`, `rise`, `thickness`, `opacity` (crisp rim), `lens` (refraction), `ink` (how much the rim bleeds into the fluid), `pop` (share that pop instead of fading). |
| `mystify.*` | see file | Mystify-style polygons (off by default since 1.3): count, points, speed, trail, line width, overlay opacity, ink (how much they bleed into the fluid). |
| `eruptions.*` | see file | Eruptions (v2): `everySeconds`, `intensity`, `duration`, `symmetry` (kaleidoscope folds in the bloom), `breakthroughEverySeconds` and `breakthroughSeconds` (whole-screen kaleidoscope, 0 = off), `takeoverEverySeconds` and `takeoverSeconds` (a drop that swallows the whole picture and brings the next palette, 0 = off). |

Built-in palettes: Prism, Lava lamp, Deep sea, Sunset, Neon, Aurora, Ultraviolet, Ember, Acid, Miami, Forest, Mono ice.

Rendering pauses while the display is powered off (`GUID_CONSOLE_DISPLAY_STATE`). Rendering is GPU-side (WebGL2);
CPU cost is the Chromium compositor at the capped frame rate.

## HTML URL parameters

`?fps=30` `?maxscale=0.75` `?scale=0.5` `?speed=2` `?palette=3` `?hint=0` `?saver=1`

Keys in the browser: click/F fullscreen, Space pause, 1-9 palette, A auto palette, S speed, O toggle bubbles, N new bubble, P pop them all, M toggle lines, E eruption now, B breakthrough now, T takeover now, R reset, H hide hint.

In a browser the page cannot read `settings.json` from `file://`; edit the `DEFAULTS` block at the top of the script instead, or serve the folder over http (then `settings.json` next to the page is picked up).

## Known limitations

* Requires the WebView2 Runtime. Built into Windows 11; on Windows 10 it comes with Edge/Office, or install the Evergreen bootstrapper.
* If Windows starts the screensaver on the secure (Winlogon) desktop, i.e. the machine is already locked, WebView2 may refuse to start. The host then exits cleanly and logs to `%LOCALAPPDATA%\AcidFlow\AcidFlow.log`; Windows simply shows the lock screen.
* A screen saver enforced by GPO/Intune under `HKCU\Software\Policies` overrides the per-user registration.
* The current `.scr` (1.3.1) was built on Windows with `src\build.ps1` (csc.exe from .NET Framework 4.8).
