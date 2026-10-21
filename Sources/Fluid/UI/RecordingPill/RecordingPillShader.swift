/// Metal source for the recording pill's rim, compiled once at launch with
/// `MTLDevice.makeLibrary(source:)`. Compiling at run time keeps the app build
/// free of the separate Metal toolchain download that Xcode 26 asks for.
///
/// The fragment function draws one continuous light field per pixel from the
/// pixel's distance to the pill outline and its position along it. It is the
/// fragment shader in the prototype's rim.js (approved 2026-10-21), ported to
/// Metal; the CPU half lives in RimSimulation.swift.
nonisolated enum RecordingPillShader {
    static let vertexFunction = "rimVertex"
    static let fragmentFunction = "rimFragment"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Offsets into the uniform array. Keep in step with RimUniform in RimSimulation.swift.
    #define U_PILL_W 0
    #define U_PILL_H 1
    #define U_FULL_W 2
    #define U_FADE 3
    #define U_SCALE 4
    #define U_PHASE 5
    #define U_WOBBLE 8
    #define U_CONTRAST 9
    #define U_EXPOSURE 10
    #define U_HUE 11
    #define U_HUE_SHIFT 12
    #define U_HUE_CYCLES 13
    #define U_TILT 14
    #define U_LOW_S 15
    #define U_HIGH_S 16
    #define U_TILT_S 17
    #define U_BAND_LIFT 18
    #define U_BANDS 19
    #define U_BLOOM_COUNT 27
    #define U_BLOOMS 28
    #define U_WIDTH 52
    #define U_WIDTH_GAIN 53
    #define U_GLOW 54
    #define U_REACH 55
    #define U_DIM_RIM 56
    #define U_STRENGTH 57
    #define U_REST_EASE 58
    #define U_CORE_ON 59
    #define U_DONE_T 60
    #define U_THINK_T 61
    #define U_REDUCED 62
    #define U_DOWNLOAD_TIME 63
    #define U_SNAP_TIME 64
    #define U_LINE_WIDTH 65
    #define U_INNER_GLOW 66
    #define U_BREATH 67
    #define U_PULSE_DEPTH 68
    #define U_LINE_PHASE 69
    #define U_LINE_BLOOMS 72
    #define U_MODE 88
    #define U_HOLD 89
    #define U_LINE_LENGTH 90
    #define U_LINE_FADE 91
    #define U_PALETTE 92
    #define U_COUNT 104

    constant float TAU = 6.28318530718;
    constant float PI_F = 3.14159265359;
    constant float HALF_PI = 1.57079632679;

    static float rimSmooth(float t) {
        t = clamp(t, 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float rimWrap(float v) { return v - floor(v); }

    static float loopDistance(float a, float b) {
        float x = abs(rimWrap(a - b));
        return x > 0.5 ? 1.0 - x : x;
    }

    static float3 labToRgb(float3 lab) {
        float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
        float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
        float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
        float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
        float3 lin = clamp(float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), 0.0, 1.0);
        return mix(12.92 * lin, 1.055 * pow(lin, float3(1.0 / 2.4)) - 0.055, step(0.0031308, lin));
    }

    static float3 paletteColour(constant float *u, int index) {
        int i = U_PALETTE + index * 3;
        return float3(u[i], u[i + 1], u[i + 2]);
    }

    static float3 paletteLab(constant float *u, float h) {
        float f = rimWrap(h) * 4.0;
        int j = int(floor(f));
        float t = rimSmooth(f - float(j));
        return mix(paletteColour(u, j % 4), paletteColour(u, (j + 1) % 4), t);
    }

    // Hue around the loop by tone (0 deep, 1 pale), in OKLab; the pale end keeps 45% chroma so it stays warm, not grey.
    static float3 tint(constant float *u, float h, float tone) {
        float3 lab = paletteLab(u, h);
        float k = clamp(tone, 0.0, 1.0);
        float lightness = mix(lab.x - 0.17, min(0.97, lab.x + 0.26), k);
        float chroma = mix(1.15, 0.45, k);
        return labToRgb(float3(lightness, lab.y * chroma, lab.z * chroma));
    }

    static float3 whiten(float3 c, float w) { return mix(c, float3(1.0, 0.98, 0.94), clamp(w, 0.0, 1.0)); }

    struct RimVertexOut {
        float4 position [[position]];
    };

    // One triangle that covers the whole drawable.
    vertex RimVertexOut rimVertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        RimVertexOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    fragment half4 rimFragment(RimVertexOut in [[stage_in]], constant float *u [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
        if (u[U_FADE] <= 0.0) { return half4(0.0); }
        float scale = max(1.0, u[U_SCALE]);
        // Pixel coordinates to points from the centre; y grows downward, as in the prototype.
        float2 p = in.position.xy / scale - 0.5 * size;
        float w = u[U_PILL_W], h = u[U_PILL_H], r = h * 0.5, hx = max(0.0, w * 0.5 - r);
        float qx = max(abs(p.x) - hx, 0.0);
        float ql = length(float2(qx, p.y));
        float d = ql - r;  // signed distance to the silhouette, + outside
        float2 n = ql > 1e-4 ? float2(sign(p.x) * qx, p.y) / ql : float2(0.0, -1.0);
        float ny = n.y, ux = clamp(p.x / max(0.5, w * 0.5), -1.0, 1.0);
        float loopLength = 4.0 * hx + TAU * r;

        // Arc length, clockwise from the left end of the top edge.
        float s;
        if (abs(p.x) <= hx) {
            s = p.y < 0.0 ? (p.x + hx) / loopLength : (2.0 * hx + PI_F * r + (hx - p.x)) / loopLength;
        } else if (p.x > hx) {
            float a = atan2(p.y, p.x - hx);
            s = (2.0 * hx + r * (a + HALF_PI)) / loopLength;
        } else {
            float a = atan2(p.y, p.x + hx);
            if (a < 0.0) a += TAU;
            s = (4.0 * hx + PI_F * r + r * (a - HALF_PI)) / loopLength;
        }
        float aTop = 2.0 * hx / loopLength;  // the mirror of s about the vertical axis is aTop - s

        // Three feathered tonal bands, integer wavenumbers (seamless), each with a slow wobble so no pass repeats.
        float wob = u[U_WOBBLE];
        float phi = 1.0 * cos(TAU * (1.0 * s + u[U_PHASE] + 0.045 * sin(TAU * (5.0 * s + 0.35 * wob))))
                  + 0.7 * cos(TAU * (2.0 * s + u[U_PHASE + 1] + 0.045 * sin(TAU * (5.0 * s + 0.35 * wob + 0.37))))
                  + 0.45 * cos(TAU * (3.0 * s + u[U_PHASE + 2] + 0.045 * sin(TAU * (5.0 * s + 0.35 * wob + 0.71))));
        phi /= 2.15;

        // Where the voice lands: 0 bottom centre, 0.5 the ends, 1 top centre, mirrored; band b lives at b/7.
        float qq = 0.5 - 0.5 * ny * (1.0 - abs(ux));
        float bandEnergy = 0.0;
        for (int b = 0; b < 8; b++) {
            float dq = qq - float(b) / 7.0;
            bandEnergy += u[U_BANDS + b] * exp(-dq * dq / 0.0578);
        }
        bandEnergy = min(1.0, bandEnergy * 0.8) * u[U_BAND_LIFT];
        float region = u[U_TILT] * (u[U_LOW_S] * max(0.0, ny) * 0.55 + u[U_HIGH_S] * max(0.0, -ny) * 0.55 + u[U_TILT_S] * (-ny) * 0.25);

        float bloom = 0.0;
        int bloomCount = min(6, int(u[U_BLOOM_COUNT]));
        for (int i = 0; i < bloomCount; i++) {
            int k = U_BLOOMS + i * 4;
            float d1 = loopDistance(s, u[k]), d2 = loopDistance(s, rimWrap(aTop - u[k]));
            bloom += u[k + 1] * (exp(-d1 * d1 / (2.0 * u[k + 2])) + exp(-d2 * d2 / (2.0 * u[k + 2]))) * u[k + 3];
        }

        float doneT = u[U_DONE_T], thinkT = u[U_THINK_T];
        float doneBump = doneT >= 0.0 ? 0.18 * rimSmooth(1.0 - abs(clamp(doneT, 0.0, 1.0) - 0.4) / 0.3) : 0.0;
        float tone = 0.5 + 0.5 * u[U_CONTRAST] * phi + region + 1.2 * bloom + 0.35 * bandEnergy + doneBump;
        if (doneT >= 0.0) tone = min(tone, 0.82);  // confirmation stays mint, never white, so it shows on a light desk too
        float hue = u[U_HUE_CYCLES] * s + u[U_HUE] + u[U_HUE_SHIFT] * phi + 0.04 * u[U_TILT_S];
        float lit = u[U_EXPOSURE] * (1.0 + 0.8 * bloom + 0.9 * bandEnergy) * u[U_DIM_RIM];
        float strength = u[U_STRENGTH];

        // Core line, centred on the silhouette; thickens by at most widthGain where light lands.
        float coreWidth = u[U_WIDTH] + u[U_WIDTH_GAIN] * min(1.0, bloom + 0.6 * bandEnergy);
        float aa = 0.75 / scale;
        float coreA = 1.0 - smoothstep(coreWidth * 0.5 - aa, coreWidth * 0.5 + aa, abs(d));
        float dimTone = 0.3 * (1.0 - clamp(lit / 0.55, 0.0, 1.0));
        float3 coreC = whiten(tint(u, hue, tone - dimTone), max(0.0, tone - 1.0) * 1.4);
        coreA *= min(1.0, 0.42 + lit * (0.5 + 0.4 * strength)) * (1.0 - 0.45 * u[U_REST_EASE]);

        // Halo: two soft falloffs within reach; the inner half is dimmed so a bloom reads as brighter, not bigger.
        float halo = 0.0;
        float reach = u[U_REACH];
        if (reach > 0.05) {
            float dd = abs(d);
            float k = 0.14 * (1.0 - smoothstep(0.5 * reach, reach, dd)) + 0.34 * (1.0 - smoothstep(0.1 * reach, 0.5 * reach, dd));
            halo = u[U_GLOW] * strength * k * lit * lit * (0.5 + 0.9 * clamp(tone, 0.0, 1.2));
            if (d < 0.0) halo *= 0.4;
        }
        float3 haloC = tint(u, hue, tone);
        float bodyA = 1.0 - smoothstep(-aa, aa, d);
        float3 body = float3(14.0, 15.0, 19.0) / 255.0;

        // Processing: on release the rim's light travels inward once and, where it converges,
        // becomes a true line along the centre with feathered ends. Complete: the line turns
        // green and holds; then one front expands back out to the rim (always shown), or the
        // whole pill collapses (only while dictating; the geometry is handled on the CPU).
        float3 innerC = float3(0.0);
        float innerA = 0.0;
        if (u[U_CORE_ON] > 0.01 && d < -0.3) {
            float din = -d, depth = h * 0.5 - 0.6, front = 0.0;
            float dl = abs(p.y);
            float downloadTime = u[U_DOWNLOAD_TIME], snapTime = u[U_SNAP_TIME], hold = u[U_HOLD];
            float halfRest = max(2.0, min(u[U_LINE_LENGTH] * u[U_FULL_W] * 0.5, hx + 0.3 * r));
            float halfNow = halfRest, lineOn = 0.0;
            if (thinkT >= 0.0) {
                float travel = u[U_REDUCED] > 0.5 ? 1.0 : rimSmooth(thinkT / downloadTime);
                float dd = depth * travel - din;
                front = exp(-dd * dd / (2.0 * 1.3 * 1.3)) * (1.0 - rimSmooth((thinkT - 0.65 * downloadTime) / (0.5 * downloadTime)));
                lineOn = rimSmooth((thinkT - 0.55 * downloadTime) / (0.5 * downloadTime));
                // Converges at the ring's length, then settles to its own.
                halfNow = mix(max(hx, halfRest), halfRest, rimSmooth((thinkT - 0.6 * downloadTime) / (0.6 * downloadTime)));
            } else if (doneT >= 0.0) {
                lineOn = 1.0;
                if (u[U_MODE] < 0.5) {
                    float tt = max(0.0, doneT - hold);
                    float snap = rimSmooth(tt / snapTime);
                    float dd2 = depth * (1.0 - snap) - din;
                    front = doneT > hold ? exp(-dd2 * dd2 / (2.0 * 1.4 * 1.4)) * (1.0 - rimSmooth((tt - 0.6 * snapTime) / (0.4 * snapTime))) : 0.0;
                    lineOn = 1.0 - rimSmooth(tt / (0.45 * snapTime));
                    halfNow = mix(halfRest, max(hx, halfRest), rimSmooth(tt / (0.35 * snapTime)));
                } else {
                    lineOn = u[U_LINE_FADE];
                }
            }
            float lu = p.x / max(1.0, halfNow);  // position along the line, -1...1
            float taper = rimSmooth((1.0 - abs(lu)) / 0.32);  // feathered ends: a line of light, not a capsule
            float taperGlow = rimSmooth((1.15 - abs(lu)) / 0.5);
            float along = 0.5 * lu + 0.5;
            float linePhi = (cos(TAU * (along + u[U_LINE_PHASE])) + 0.7 * cos(TAU * (2.0 * along + u[U_LINE_PHASE + 1]))
                             + 0.45 * cos(TAU * (3.0 * along + u[U_LINE_PHASE + 2]))) / 2.15;
            float br = 0.5 - 0.5 * cos(TAU * u[U_BREATH]);
            float pulseDepth = u[U_PULSE_DEPTH];
            float pulse = 1.0 - pulseDepth + pulseDepth * (0.35 + 0.65 * br) * 1.25;
            float lineBloom = 0.0;
            if (thinkT >= 0.0) {
                for (int i = 0; i < 4; i++) {
                    int k = U_LINE_BLOOMS + i * 4;
                    float dx = lu - u[k];
                    lineBloom += u[k + 1] * exp(-dx * dx / (2.0 * max(1e-4, u[k + 2]))) * u[k + 3];
                }
            }
            float lw = u[U_LINE_WIDTH] * (1.0 + 0.55 * min(1.0, lineBloom) + 0.15 * br);
            float lineB = exp(-dl * dl / (2.0 * lw * lw)) * taper;
            float glowB = exp(-dl * dl / (2.0 * 3.2 * 3.2)) * taperGlow * u[U_INNER_GLOW] * (1.0 + 1.6 * lineBloom + 0.6 * br);
            float lineAmp = (lineB * (0.62 + 0.25 * (0.5 + 0.5 * linePhi) + 0.5 * lineBloom) + glowB * (0.6 + 0.4 * (0.5 + 0.5 * linePhi))) * pulse * lineOn;
            float lineHue = u[U_HUE_CYCLES] * 0.5 * along + u[U_HUE] + 0.08 + 0.06 * linePhi;
            float lineTone;
            if (doneT >= 0.0) {
                lineTone = 0.55 + 0.12 * min(1.0, front);  // a clear green, as bright as the working line, never white
                lineAmp *= 1.35;
            } else {
                lineTone = max(0.42 + 0.22 * linePhi + 0.55 * lineBloom + 0.12 * br, 0.3 + 0.6 * min(1.0, front));
            }
            float amp = front * 0.9 + lineAmp;
            if (amp > 0.02) {
                innerC = whiten(tint(u, lineHue, lineTone), doneT >= 0.0 ? 0.0 : max(0.0, max(amp, lineTone) - 0.95) * 1.5);
                innerA = pow(min(1.3, amp), 1.2) * 0.9 * u[U_CORE_ON] * (0.6 + 0.4 * strength);
            }
        }

        // Compose, premultiplied: body, inner light added, halo added, core over.
        float3 colour = body * bodyA;
        float alpha = bodyA;
        colour += innerC * innerA * bodyA;
        colour += haloC * halo;
        alpha = min(1.0, alpha + halo);
        colour = colour * (1.0 - coreA) + coreC * coreA;
        alpha = alpha * (1.0 - coreA) + coreA;
        return half4(half3(colour), half(alpha)) * half(u[U_FADE]);
    }
    """
}
