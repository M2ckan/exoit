# AcidFlow

GPU-rendered psychedelic flow screensaver. v2 adds eruptions: small drops of colour that ripple the fluid and leave a
kaleidoscopic bloom behind, plus rare whole-screen "breakthroughs" where the picture folds in on itself. One self-contained HTML file (`AcidFlow.html`) plus a
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
| `mystify.*` | see file | Mystify-style polygons: count, points, speed, trail, line width, overlay opacity, ink (how much they bleed into the fluid). |
| `eruptions.*` | see file | Eruptions (v2): `everySeconds`, `intensity`, `duration`, `symmetry` (kaleidoscope folds in the bloom), `breakthroughEverySeconds` and `breakthroughSeconds` (whole-screen kaleidoscope, 0 = off). |

Built-in palettes: Prism, Lava lamp, Deep sea, Sunset, Neon, Aurora, Ultraviolet, Ember, Acid, Miami, Forest, Mono ice.

Rendering pauses while the display is powered off (`GUID_CONSOLE_DISPLAY_STATE`). Rendering is GPU-side (WebGL2);
CPU cost is the Chromium compositor at the capped frame rate.

## HTML URL parameters

`?fps=30` `?maxscale=0.75` `?scale=0.5` `?speed=2` `?palette=3` `?hint=0` `?saver=1`

Keys in the browser: click/F fullscreen, Space pause, 1-9 palette, A auto palette, S speed, M toggle lines, E eruption now, B breakthrough now, R reset, H hide hint.

In a browser the page cannot read `settings.json` from `file://`; edit the `DEFAULTS` block at the top of the script instead, or serve the folder over http (then `settings.json` next to the page is picked up).

## Known limitations

* Requires the WebView2 Runtime. Built into Windows 11; on Windows 10 it comes with Edge/Office, or install the Evergreen bootstrapper.
* If Windows starts the screensaver on the secure (Winlogon) desktop, i.e. the machine is already locked, WebView2 may refuse to start. The host then exits cleanly and logs to `%LOCALAPPDATA%\AcidFlow\AcidFlow.log`; Windows simply shows the lock screen.
* A screen saver enforced by GPO/Intune under `HKCU\Software\Policies` overrides the per-user registration.
* The current `.scr` (1.2.1) was built on Windows with `src\build.ps1` (csc.exe from .NET Framework 4.8).
