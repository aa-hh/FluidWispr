Worked example from the media-manager-2 sign-in (Oct 2026). Replace the product, paths, colours and {{placeholders}} for a new job.

You are a creative coder. Build ONE quick sign-in screen prototype for media-manager-2: a generative, algorithm-driven animation, no illustrations, no image files. This is a FAST round: idle animation only, judged on direction, not polish. Budget: about 10 minutes of work. Stop when the idea reads clearly.

PRODUCT (flavour only): a single-owner web app that runs Sonarr + Radarr, watches rTorrent downloads from private trackers, feeds a Plex library the owner streams from. Sign-in is Plex only: one button "Sign in with Plex", a line saying only the owner's Plex account can open the app, a line saying Plex is used only to confirm identity. Name: media-manager-2. Quality bar: omp.sh (every pixel from arithmetic, dense texture, restraint in motion). Ignore the repo's design docs; do not read them. No amber/yellow accents. The app's green #C6F135 is reserved for a later success state; do not use it now.

YOUR DIRECTION: {{DIRECTION}}

DELIVERABLE, one file: /Users/alechenderson/Projects/media-manager-2/.claude/worktrees/login-screen-brand-concepts-95c9b2/design/discovery/sign-in-generative/{{FILE}}
- Plain HTML + CSS + vanilla JS, Canvas 2D. No libraries, no fetches, no images, no network fonts. Runs from file:// and from a static server.
- Full-viewport animation with the sign-in block over it (heading, two copy lines, Plex button with an inline SVG chevron: copy the path data from ../../../design/logos/plex-icon.svg in this worktree). Text readable at all times.
- Idle state only. No ?state handling needed. Respect prefers-reduced-motion by freezing.
- TWEAK PANEL (required): a small collapsible panel in the bottom-right corner (toggle with the T key) with range sliders for the 5 to 8 constants that most change the feel (speed, density, scale, contrast, band count, colours as hue sliders, etc.). Sliders update the animation live. A "Copy values" button puts the current values on the clipboard as JSON, and the panel shows them as text too, so Alec can paste them back to me.
- Half-resolution rendering is fine. Check it runs: capture one still with headless Chrome and look at it with the Read tool:
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --window-size=1440,900 --virtual-time-budget=4000 --screenshot=<your scratchpad>/check.png "file://<abs path>"
  (ignore the "allocator" stderr line). Fix if blank or broken. Do not use the shared browser pane. Do not write to the pen file. Do not commit.

FINISH: reply with 3 lines on what it does and anything that went wrong. Short.
