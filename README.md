# FLTHUD · FLTHD2 — Glass-Cockpit Telemetry for the RadioMaster TX16S

A free **EdgeTX widget** that turns the whole TX16S screen into an F1 "pit-wall" telemetry
dashboard: shift-light RPM, live amps, a countdown pit timer, per-cell battery health,
computed power / pack internal resistance, a fuel gauge, and a link-quality meter.

One `main.lua` file. It reads whatever your receiver reports and **degrades gracefully**
when a sensor isn't present.

## Download
- Grab **`FLTHD2-main.lua`** (or use the Download button on the site) and install it as
  **`SD:/WIDGETS/FLTHD2/main.lua`** on your radio's SD card.
- If updating, also delete any `main.luac` in that folder (EdgeTX caches a compiled copy).

## Install (short version)
1. Copy the file to `SD:/WIDGETS/FLTHD2/main.lua`.
2. Reboot the radio (leave USB storage mode).
3. **Model → Telemetry → Discover** your sensors (power the model first).
4. **Model → Screens** → set a screen to **Full screen (1×1)** → widget **FLTHD2**.
5. Optional: set the widget's **PackX100** option to your pack size (×100 mAh) and set up **Timer 1** for the countdown.

Full step-by-step, receiver compatibility, and a live animated preview are on `index.html`.

## Receiver support (at a glance)
| System | What you get |
|---|---|
| **Spektrum** AR631/AR631Plus + SMART ESC | Full dashboard — per-cell V, current, RPM, temp, link log |
| **FrSky** ACCST/ACCESS | RSSI + RX voltage; add FAS/FLVSS/GPS for the rest |
| **FlySky** AFHDS | Bare bones — link + any reported voltage |
| Anything on EdgeTX | Matches standard sensor names; hides what's missing |

## Live demo / hosting
`index.html` is a single self-contained page (no dependencies) — open it directly, serve it
locally (`python -m http.server 8080`), or publish it with **GitHub Pages** (Settings → Pages
→ deploy from branch, root). The download button works in all three.

---
For RadioMaster TX16S on EdgeTX color radios. Free to use and share.
