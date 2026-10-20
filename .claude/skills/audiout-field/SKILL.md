---
name: audiout-field
description: Use when working on Audiout's emitter field — the concentric rings that radiate from a speaker and carry the brand across the marketing site hero, the shelf and house backgrounds, the Open Graph social card, and the Mac app's first-open licence window. Covers adding the field to a new surface, porting it to a new technology (WebGL, SVG, Metal, Canvas, SwiftUI), changing its constants, checking a port has not drifted from the reference, and rendering static images of it. Trigger on "emitter", "the field", "the rings", "hero background", "house background", "shelf background", "social card", "OG card", "splash background", or a request to make some new surface look like the site's hero. Applies in every Audiout repo: the Mac app, the website, the iPhone companion, and audiout-shared.
---

# The Audiout emitter field

One visual, drawn four different ways. Concentric rings leave a speaker, bend
slightly, fall off as they cross the room, and breathe. It is the brand's only
moving image, so every surface has to be the same field — not a lookalike.

**The rule that matters: the numbers live in one file and ports read them.
Never retype a constant.** Every drift this skill exists to prevent started as
a hand-copied number.

## Where the numbers live

**`Sources/AudioutField/field.json`** in **audiout-shared** —
`git@github.com:aa-hh/audiout-shared.git`, on `main` since tag **0.2.0**.
The `defaults` object holds the 26 field knobs; `ramps` holds the three named
colour ramps ("Movie night" is Sync Green, "Chill out" gold, "Dinner party"
Party Magenta).

- **Swift**: add the `AudioutField` product, read `AudioutField.defaults` and
  `AudioutField.ramps`. Data only — it carries no drawing code, and it traps
  rather than falling back to literals if the resource is missing.
- **JS**: `npm i github:aa-hh/audiout-shared#0.2.0`, then
  `import field from "audiout-shared/Sources/AudioutField/field.json" with { type: "json" }`.
  The package exposes that one file and nothing else.
- **Python / anything else**: read the JSON.

Changing a number there is a brand change that reaches every surface. Tag a new
version and move the consumers' pins in the same session.

## The second state: settled

Since 2026-09-13 the field has a second, opt-in state (shared PR #16):
fully emitted, nothing travels outward — each ring rolls over itself in
place while a compression lobe orbits the source. Its constants are the
`settled` block in `field.json` (`AudioutField.settled` in Swift); the
formula and the rulings behind it are in the Mac repo's
`dev/notes/settled-emitter-state.md`. It replaces the hero's steps 3–4 and
the breathing values; everything else is shared. `settled.timeScale`
multiplies the port's time input ONCE — never fold it into individual
rates. The radiating state is untouched; a surface chooses one or the other.

## The four implementations

| Where | Technology | Role |
|---|---|---|
| Website `src/scripts/fields/emitters.js` | generates GLSL, runs as a WebGL fragment shader | The reference. **Reads `field.json`** — no literals. Consumed by `house-bg.js`, `house-groups-bg.js`, `shelf-bg.js`, `fields/d.js` |
| Website `tools/og-card/emitter.js` | exact SVG evaluation | Static renders. Verified against the WebGL at mean difference 0.69/255 — the shader's own dither |
| Website `tools/og-card/check.py` | Python port of the same maths | Measures a render against hard constraints; re-reads `emitter.js` at run time so it cannot drift |
| Website `tools/og-card/card.html` | its own `window.OG_FIELD` literals | Rendered in headless Chrome with no bundler, so it **cannot** import the JSON. Guarded instead — see below |
| Mac app `AudioutCore/Sources/AudioutOnboardingUI/EmitterFieldView.swift` | Metal fragment shader | The first-open licence window. **Reads `field.json`** — the MSL is generated from `AudioutField.defaults` at runtime, and `EmitterFieldTests` fails if it stops matching. On branch `claude/quieter-license-key-emitters-f5f90c` (which carries the licence gate too), not main |

Read the reference before porting anything. `emitters.js` has a long header
that explains every knob in prose, and `tools/og-card/README.md` (19KB) covers
the static-render side including the failure modes below.

## The mechanism

Per emitter `k`, with `seed = k * 6.13 + 1.7`:

1. **Orbit** — the centre drifts on two slow sines off `seed`, so the sources
   never sit still.
2. **Squash** — distance is measured with y scaled by `squash`, so wavefronts
   read as slight ovals rather than clock faces.
3. **Wobble** (optional, `0` on the hero) — two harmonics, three and five
   lobes, phased by `seed`, scale the radius by angle only. Because they scale
   *distance*, the centre never moves — and because the modulation is a
   function of angle alone, every locus of constant radius is the same closed
   curve at a different scale. That property is what makes the exact SVG form
   possible: draw the curve once, stroke concentric copies, each copy carries
   one exact field value.
4. **Rings** — `pow(0.5 + 0.5*sin(r*dens - t*speed + seed), sharp)`: thin
   bright crests, wide dark gaps.
5. **Falloff** — `exp(-r * fade)`, loudest at the source.
6. **Breathing** — a slow swell per emitter, `breatheFloor + breatheDepth * …`.
7. **Stepping** — `speed`, `dens` and `breatheRate` each step per emitter off a
   shared base. This is what keeps the sources out of phase with each other. It
   comes free from the field; never fake it with a random offset.

## Shared versus per-surface

**Shared — comes from `field.json`, changing it is a brand change:**
`orbit`, `squash`, `speedBase`/`speedStep`, `densBase`/`densStep`, `sharp`,
`fade`, the breathing group, `gain`, `paperLift`, the wobble pair, and the
`seed` formula.

**Per-surface — the implementer chooses, no drift risk:**
emitter positions, per-emitter `size` and `reach`, the colour ramp, canvas
size, and the `sequence` / `emerge` behaviours (a hero is continuous; a window
that opens may want a one-shot birth).

**Deliberate deviations are allowed, but must be marked inline and justified.**
The Mac port is the model, and its standard is one number with one reason:
it declares exactly ONE — `stageScale` ×5 on ring density and ring speed
*together*, because the site's crest spacing is ~163 pt against a 440 pt
stage, and because scaling both leaves crest velocity (speed/density) at the
site's own. Everything else that window does differently is a per-surface
choice: where its three sources sit, their `size` and `reach`, and its ramp.
**Reach for those before you touch a shared knob** — they carry no drift risk
and they are where a surface's character is supposed to come from. Anything
not marked is drift.

## When a surface cannot import the JSON

`tools/og-card/card.html` is the standing example: headless Chrome renders it
straight from disk, so there is no module resolution. It keeps its literals and
`scripts/check-field.mjs` compares them against the shared defaults on every
`npm run build` — the build fails on an unexplained difference, naming the key,
both values and the file.

A deliberate difference goes in that script's `ALLOWED_DEVIATIONS` **with its
reason**. Two are allow-listed today: `sharp: 3.0` against the shared `4.0`
(reason in `card.html`: crest band 17.3px at half max, where 4.0 gives 14.9px),
and `wobble: 0.045` against the shared `0` — which carries **no explanation
anywhere** and is marked `UNDOCUMENTED` pending a ruling. Do not copy that
pattern; an unexplained deviation is drift that happens to be written down.

The checker compares only the shared knobs. Per-surface choices — emitter
positions, `sequence`/`cycle`/`duty`/`rise`/`tail`/`reach`/`front`/`emerge` —
are excluded on purpose, since differing there is the point.

## Adding a new port

1. Read `emitters.js` end to end. The header is the spec.
2. Take the numbers from `field.json`. If your platform cannot read it,
   fix that first — do not paste the values in "just for now."
3. Implement the seven steps above in your technology.
4. Add a test that asserts your local constants equal `field.json`'s. Without
   it the port is unverified, however good it looks.
5. Mark every deliberate deviation inline, with the reason.
6. Render one frame at a fixed `t` and compare it against the reference before
   claiming it matches. The bar the SVG port cleared is mean 0.69/255.

## Static renders

The site's Open Graph card is built from `tools/og-card/`:

```bash
./build.sh                                      # rewrites ../../public/og.png
./build.sh /tmp/try.png 'phase=180&opacity=0.7' # one variation
./sweep.sh variants.txt                         # N variations, one contact sheet
./check.py /tmp/try.png 'phase=180'             # measure one render
```

Every knob in `card.html` and `emitter.js` is settable from the query string,
and a bad parameter renders a red error card rather than silently falling back.

## Traps

- **Truecolour, always.** A three-stop ramp cannot survive a 256-colour
  palette; the card shipped broken once as an 8-bit palette PNG. Verify with
  `Image.open(path).mode` → must be `RGB`, never `P`.
- **`phase` is geometry-dependent.** It decides where crests land, so a phase
  chosen at one mark size, reach or squash means nothing at another. Re-shop it
  whenever the geometry moves.
- **Gold hue is size-dependent under a circular field.** Which crest lands on
  the mark's gold halo scales with icon size. Measured at reach 620: size 300
  fails (3.32 % of gold pixels shift, worst 31.6°), 340 and 360 pass.
  Re-measure after any change to icon size, reach or phase.
- **The grain is not decoration.** It dithers the ramp's falloff so it does not
  band.
- **The field is ornament.** It decides nothing and holds no state beyond what
  its host hands it. Under Reduce Motion it holds a recomposed still rather
  than looping, and headless runs must not create a GPU device at all, or
  snapshot tests stop being deterministic.
