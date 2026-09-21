#version 300 es

// This is a fragment shader. If you've opened this file first, please
// open and read lambert.vert.glsl before reading on.
// Unlike the vertex shader, the fragment shader actually does compute
// the shading of geometry. For every pixel in your program's output
// screen, the fragment shader is run for every bit of geometry that
// particular pixel overlaps. By implicitly interpolating the position
// data passed into the fragment shader by the vertex shader, the fragment shader
// can compute what color to apply to its pixel based on things like vertex
// position, light position, and vertex color.
precision highp float;

uniform vec4 u_Color;      // The color with which to render this instance of geometry.
                           // Here it tints the whole gradient, so a neutral white
                           // leaves the fire palette exactly as authored.

uniform float u_Time;      // Seconds elapsed since the program started. Same clock the
                           // vertex shader displaces with, so color and geometry stay in step.

uniform vec3 u_CameraPos;  // World-space eye position, for the grazing-angle rim glow.

uniform float u_Heat;      // 0.5 leaves the gradient alone; higher pushes more of the
                           // surface toward the hot end, lower cools it down.

uniform float u_Flicker;   // Strength of the animated shimmer across the surface.

uniform float u_Bands;     // Number of quantized color bands. Below 2 the gradient stays
                           // smooth; higher values give the painted, cel-shaded look.

// These are the interpolated values out of the rasterizer, so you can't know
// their specific values without knowing the vertices that contributed to them
in vec4 fs_Nor;
in vec4 fs_LightVec;
in vec4 fs_Col;

in float fs_Disp;          // The vertex shader's total displacement, remapped to [0, 1].
                           // This is what ties the color gradient to the geometry.
in float fs_Fbm;           // Just the high-frequency FBM layer, for finer mottling.
in float fs_Height;        // 0 at the root of the flame, 1 at the crown.
in float fs_Pulse;         // [0, 1] phase of the explosion cycle.
in vec4 fs_Pos;            // Displaced world-space position of this fragment.

out vec4 out_Col; // This is the final output color that you will see on your
                  // screen for the pixel that is currently being processed.

// ---------------------------------------------------------------------------
// Fire palette. The gradient runs from cooled-over crust up to a white-hot core;
// fs_Disp picks the stop, so crests read hot and crevices read dark.
// ---------------------------------------------------------------------------
// Fire burns hottest where it is fed and cools as it rises, so this runs from a
// charred crown down to a white-hot root. Stop placement follows that: the pale
// end owns a wide slice at the bottom, the dark end a narrow one at the tip.
const vec3 CHARRED = vec3(0.07, 0.04, 0.04); // burnt-out tips at the very top
const vec3 EMBER   = vec3(0.30, 0.05, 0.02);
const vec3 BLOOD   = vec3(0.70, 0.11, 0.02); // deep red upper body
const vec3 ORANGE  = vec3(0.97, 0.35, 0.03); // the body of the flame
const vec3 AMBER   = vec3(1.00, 0.65, 0.10);
const vec3 STRAW   = vec3(1.00, 0.88, 0.42);
const vec3 COREHOT = vec3(1.00, 0.99, 0.92); // white-hot root

// ---------------------------------------------------------------------------
// Toolbox functions (see the Toolbox Functions slides). GLSL has no include
// mechanism, so the ones shared with the vertex shader are repeated here.
// ---------------------------------------------------------------------------

// 1) Perlin's bias: pushes t toward 0 or 1 without leaving the [0,1] range.
float bias(float b, float t)
{
    return pow(t, log(b) / log(0.5));
}

// 2) Perlin's gain: reshapes contrast around 0.5. Above 0.5 it pushes values
//    away from the middle, sharpening them; below 0.5 it pulls them toward it.
//    0.5 is the identity.
float gain(float g, float t)
{
    return (t < 0.5) ? bias(1.0 - g, 2.0 * t) * 0.5
                     : 1.0 - bias(1.0 - g, 2.0 - 2.0 * t) * 0.5;
}

// 3) Triangle wave: ramps up and back down over [0, amp], with no rounding at
//    the turns. Its hard corners read as a flicker rather than a smooth throb.
float triangleWave(float x, float freq, float amp)
{
    return abs(mod(x * freq, amp * 2.0) - amp);
}

// 4) Smootherstep (Perlin's quintic ease): C2-continuous ease-in/ease-out. Used
//    to blend between palette stops so no band edge is visible.
float smootherstep(float a, float b, float t)
{
    t = clamp((t - a) / (b - a), 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// 5) Cubic pulse: a smooth bump of width w centered on c, zero everywhere else.
//    Targets a narrow slice of the gradient without touching the rest of it.
float cubicPulse(float c, float w, float x)
{
    x = abs(x - c);
    if (x > w) {
        return 0.0;
    }
    x /= w;
    return 1.0 - x * x * (3.0 - 2.0 * x);
}

// Walk up the palette, easing between each pair of stops. Layering the mixes
// this way keeps the ramp continuous while letting each band own its own slice.
vec3 fireRamp(float t)
{
    t = clamp(t, 0.0, 1.0);

    vec3 c = CHARRED;
    c = mix(c, EMBER,   smootherstep(0.00, 0.13, t));
    c = mix(c, BLOOD,   smootherstep(0.09, 0.27, t));
    c = mix(c, ORANGE,  smootherstep(0.22, 0.44, t));
    c = mix(c, AMBER,   smootherstep(0.40, 0.60, t));
    c = mix(c, STRAW,   smootherstep(0.56, 0.74, t));
    c = mix(c, COREHOT, smootherstep(0.72, 0.88, t));
    return c;
}

void main()
{
    vec3 nor  = normalize(vec3(fs_Nor));
    vec3 lgt  = normalize(vec3(fs_LightVec));
    vec3 view = normalize(u_CameraPos - vec3(fs_Pos));

    // The dominant term is position along the flame. Fire is fed at its root, so
    // the base burns white-hot and everything cools on the way up until the
    // crown is charred. Gain above 0.5 drives the two ends apart, which widens
    // the white core at the base and deepens the char at the tip.
    float heat = gain(0.68, 1.0 - fs_Height);

    // Stay correlated with the vertex shader's displacement: a tongue that has
    // pushed further up has travelled further from the fuel, so it reads cooler
    // than the body it came from.
    heat -= 0.24 * (fs_Disp - 0.5);

    // Fold in the fine FBM layer on its own, which mottles the flame at a finer
    // scale than the low-frequency sway reaches.
    heat *= mix(0.84, 1.12, fs_Fbm);

    // Animated flicker. Offsetting the wave's phase by world position means the
    // surface shimmers unevenly instead of strobing as one unit.
    float phase = dot(vec3(fs_Pos), vec3(1.9, 2.7, 2.3));
    heat += u_Flicker * 0.14 * (triangleWave(u_Time * 1.6 + phase, 1.0, 1.0) - 0.5);

    // The surge cycle flashes the whole flame hotter as it swells.
    heat += 0.16 * fs_Pulse;

    // Finally the heat slider biases the whole ramp hotter or cooler.
    heat = bias(clamp(u_Heat, 0.05, 0.95), clamp(heat, 0.0, 1.0));

    // Quantize into bands for the painted look of stylized fire. Jittering the
    // threshold with the FBM layer makes each band edge wander across the
    // surface instead of ringing the flame in a clean horizontal line.
    if (u_Bands >= 2.0) {
        float wobbled = heat + 0.07 * (fs_Fbm - 0.5);
        heat = floor(wobbled * u_Bands + 0.5) / u_Bands;
    }

    vec3 color = fireRamp(heat);

    // Fire is emissive, so the Lambert term barely registers - just enough to
    // keep the form readable. It never drives the unlit side toward black.
    float diffuseTerm = max(dot(nor, lgt), 0.0);
    color *= mix(0.92, 1.10, diffuseTerm);

    // Rim glow, but only down where the flame is actually hot, so the charred
    // crown keeps a hard dark edge instead of being outlined in light.
    float fresnel = pow(1.0 - max(dot(nor, view), 0.0), 3.0);
    color += STRAW * fresnel * heat * (0.22 + 0.30 * fs_Pulse);

    // Embers: a narrow slice of the noise, showing only up in the charred crown,
    // where a few flecks are still glowing.
    float embers = cubicPulse(0.86, 0.06, fs_Fbm) * smootherstep(0.55, 1.0, fs_Height);
    color += ORANGE * embers * 1.4;

    // Compute final shaded color
    out_Col = vec4(color * u_Color.rgb, u_Color.a);
}
