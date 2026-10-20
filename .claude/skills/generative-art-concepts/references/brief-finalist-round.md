Worked example from the media-manager-2 sign-in (Oct 2026). Replace the product, paths, colours and {{placeholders}} for a new job.

You are a creative coder and product designer. Revise ONE existing sign-in prototype for media-manager-2 after Alec's review. Edit the file in place. Keep its look, states wiring (?state=idle|checking|success, click → checking → success after 4 s, ?t= deterministic stills, ?bench=1, reduced motion, 390-wide phone), tweak panel (T key, sliders, Copy values), and its calm. No wrong-owner state exists. No amber. The green #C6F135 is allowed only where your direction says.

PRODUCT (flavour only): a single-owner web app that runs Sonarr + Radarr, watches rTorrent downloads, feeds a Plex library. Sign-in is Plex only; after the owner presses the button the app waits for Plex to confirm, then opens on the library. Quality bar: omp.sh (pixels from arithmetic, dense texture, restraint).

BUTTON RULE (all three prototypes, from Alec): the button keeps its idle colours in every state; it never turns green. Copy: idle "Sign in with Plex"; checking and success both read "Logging in" (checking may add a trailing ellipsis "Logging in…"; success plain "Logging in"), disabled while checking and after.

YOUR FILE AND DIRECTION: {{DIRECTION}}

CPU (Alec: "way too intensive on the CPU", measured in his own Chrome at retina density; this is the main job)
Target: idle state ≤ 5% of one CPU core in a real browser at 1440x900, devicePixelRatio 2; checking ≤ 8%; success transition may spike for its 1.5 s then settle to the idle budget. The pixel budget per second is the number that matters: pixels touched per frame × frames per second. Cut both.
Measure it, before and after, like this (headless Chrome rasterises on the CPU so it is pessimistic, but before/after is comparable):
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --window-size=1440,900 --force-device-scale-factor=2 "file://<abs path>?state=idle" >/dev/null 2>&1 &
  sleep 6; for i in 1 2 3 4 5; do ps -A -o %cpu,command | grep -E "Google Chrome Helper \(Renderer\)" | grep -v grep | awk '{s+=$1} END {print s}'; sleep 2; done; kill %1
  Report the median of the five samples for idle, checking and success (success sampled after its transition has settled). Also keep the ?bench=1 ms-per-frame numbers.
Levers, in order of payoff:
1. Frames per second. Idle motion in all three is slow. Run idle and checking at 20 to 24 fps with a fixed timestep (accumulate time, draw when ≥ 1/24 s); success and the 1 s after any state change at 60. Stop the loop when document.hidden, and when nothing changed in a frame, do not draw.
2. Pixels per frame. Never touch the whole canvas per frame unless everything changed. For glyph grids: drop the CPU pixel buffer + putImageData for the main path; draw only the cells that changed with ctx.clearRect + ctx.drawImage from the glyph atlas canvas (hardware-accelerated), tracking per-cell last-drawn state; a full redraw only on resize or on the success wave. For per-pixel planets: move the per-pixel work to a WebGL fragment shader (noise, domain warp, shading, grain, dither all on the GPU; the cloud state as a small texture or purely time-driven) so the CPU does almost nothing per frame; render the canvas at half resolution and let CSS scale it. This is the one case WebGL is wanted. If you keep any CPU raster, it is half resolution at most.
3. Resolution. A canvas at dpr 2 is 4x the pixels of dpr 1. Glyphs need dpr 2 to stay crisp, so earn it by touching few cells; everything else renders at dpr 1 or below and scales.
4. No per-frame allocations, lookup tables for noise/sine/palette, integer maths in inner loops.
After the work, run the CPU measurement again in all three states and report before/after. If a target is missed, say by how much and what you'd do next; do not claim it is met without the numbers.

CHECK: capture one still per state with headless Chrome (--screenshot, t=3 for checking, t=3 for success after the transition) into your scratchpad and look at each with the Read tool. Fix anything blank or broken. Do not use the shared browser pane. Do not write to the pen file. Do not commit.

FINISH: reply with: what changed visually (one line per state); the CPU % table before/after (three states); the ms-per-frame table; what you changed for CPU; anything that went wrong. Short, plain words.
