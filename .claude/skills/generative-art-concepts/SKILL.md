---
name: generative-art-concepts
description: Explore and build algorithm-driven artwork for a screen (sign-in, splash, empty state, hero, background) through divergent subagent prototypes, a gallery Alec flips through, fast tuning rounds, then states, performance and design-file screens. Use when Alec wants a screen to have character, brand or artwork, or names generative art, creative coding, procedural, shader or "movement based on maths".
---

# Generative art concepts

The process that produced the media-manager-2 planet sign-in (11–12 Oct 2026). Alec is the judge at every gate; you orchestrate, subagents build, and you check every result yourself in a browser before showing it.

Worked briefs from that run, adapt rather than copy: [quick round](references/brief-quick-round.md), [finalist round](references/brief-finalist-round.md).

## Steps

1. **Anchor on a reference Alec likes.** Ask for a site, video or image. Read how it is built (open it, read its script) and describe the mechanism in plain maths: what is computed per pixel or per particle, what moves, how slowly. That description is the quality bar in every brief. Illustrated themes (mascots, scenes, poster walls) failed here; motion from maths with dense texture and restrained movement won.
   Done when: the brief has a three-to-five line mechanical description of the reference.

2. **Fan out divergent directions.** One subagent per algorithm family, launched together in the background with `model: "opus"`. Families that worked: per-pixel noise with dither, particles in a flow field, reaction-diffusion, glyph grid, line fields and moiré, per-pixel shaded planets. Each brief: the reference mechanism, its one family, freedom from the brand docs (exploration only), no image files, no libraries, no amber unless asked.
   Done when: five agents are running, each with a different family.

3. **Keep rounds fast.** Each prototype is one self-contained HTML file with the idle animation only, plus a tweak panel (T key, 5–8 sliders for the constants that change the feel, a Copy values button) so Alec tunes it himself and pastes values back. No states, stills or design-file work yet. Put every prototype behind one gallery page (arrow keys between concepts, number keys for states, P for phone width) served from a local static server.
   Done when: each prototype runs in the gallery and you have looked at it live.

4. **Narrow with Alec.** He picks favourites and says what is off. Run two variants per pick, each pushing one idea. When variants drift abstract, the fix is to copy the liked file and change as little as possible. Move the survivors to a separate finalists page.
   Done when: Alec names the finalist(s).

5. **Design the states into the animation.** Idle; waiting (calm enough to sit on screen for 30 s); success as a payoff that changes the maths (bands straighten, flow locks, eddy unwinds) rather than a colour wash, with the app's accent as a thin edge at most. Errors stay out of the animation; they are one text line under the control. Transitions blend over 400–800 ms. Support `?state=` and `?t=<seconds>` (seeded, deterministic) for stills, `?bare=1` to hide the UI, and reduced motion as a frozen frame.
   Done when: every state can be opened by URL and by clicking through.

6. **Make it cheap to run.** Measure CPU percentage of one core for the page's renderer in a real browser with nothing else running, before and after. Targets: idle ≤ 5%, waiting ≤ 8%. Levers in order: per-pixel work in a WebGL fragment shader; canvas at half resolution scaled by CSS; 20–24 fps for slow states, 60 only during transitions; stop the loop when the tab is hidden; no per-frame allocations; for glyph grids, redraw only changed cells from a glyph atlas.
   Done when: you have the before/after CPU numbers for every state.

7. **Put it in the design file.** Capture planet-only stills with `?bare=1`, then build each state as a screen from the library's own components over the still, in the screen file's DISCOVERY section. Follow Alec's button and copy rules (spinner-only button, line under the button, scrim not a box). Any new control style becomes a library variant with all its states before code.
   Done when: desktop and phone screens exist for every state and Alec approves the layout.

8. **Build it in the app.** Run `/scope-and-run`: the shader and constants port verbatim; the work order maps the app's real flow states onto the animation states and lists the ones that don't fit as questions for Alec. Then open the real screen in a browser at desktop and phone width yourself.
   Done when: build and tests pass and you have looked at the running screen in both widths.

## Reference

Headless Chrome for stills: it will not go narrower than 500 px (frame the page in a 390-wide iframe and crop); `--disable-gpu` turns WebGL off; it can hang after `--screenshot` on an animated page, so run it in the background, wait for the file, then kill your own process.

Subagents writing to one pen.dev file: give each its own lane frame, small `execute` calls, no `SetVariables`, and the stroke and image-fill syntax up front (`stroke:{type:"color",color}` with `strokeWidth`; image fill `mode:"cover"`).
