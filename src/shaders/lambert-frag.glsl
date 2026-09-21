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

uniform float u_Flow;      // How strongly the flowing noise warps the color gradient.

uniform float u_Bands;     // Number of quantized color bands. Below 2 the gradient stays
                           // smooth; higher values give the painted, cel-shaded look.

uniform float u_BandBlend; // How much of each band's width is spent crossing into the
                           // next: 0 gives hard cel edges, 1 an unbroken gradient.

// Shared with the vertex shader, so the color streams upward at the same rate
// the geometry churns at.
uniform float u_RoilSpeed;

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

// 3) Smootherstep (Perlin's quintic ease): C2-continuous ease-in/ease-out. Used
//    to blend between palette stops so no band edge is visible.
float smootherstep(float a, float b, float t)
{
    t = clamp((t - a) / (b - a), 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// 4) Cubic pulse: a smooth bump of width w centered on c, zero everywhere else.
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

// ---------------------------------------------------------------------------
// Per-pixel noise. The vertex shader has its own copy; GLSL has no include
// mechanism, and this has to be evaluated per fragment rather than interpolated
// from the vertices, or the color boundaries could only ever be straight lines
// between one vertex and the next.
// ---------------------------------------------------------------------------

// Both fixed rather than slider-driven. The octave count keeps the per-pixel
// cost constant, and the scale is in world units rather than a multiple of
// u_FbmScale, so pushing the geometry's detail up does not shatter the color
// into speckle - the two are separate art-direction decisions.
const int   COLOR_OCTAVES = 3;
const float COLOR_SCALE   = 1.5;

float hash31(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float valueNoise(vec3 p)
{
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
    float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash31(i + vec3(1.0, 1.0, 1.0));

    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
               u.z);
}

float fbm(vec3 p)
{
    float sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0;
    for (int i = 0; i < COLOR_OCTAVES; ++i)
    {
        sum  += amp * valueNoise(p * freq + float(i) * 17.3);
        norm += amp;
        amp  *= 0.5;
        freq *= 2.0;
    }
    return sum / norm;
}

// Quantize x into `bands` steps, crossing between them over a `blend` fraction
// of each step instead of snapping. blend near 0 gives hard cel edges, blend of
// 1 gives back a continuous ramp. Monotone and continuous at every boundary.
float posterize(float x, float bands, float blend)
{
    if (bands < 2.0) {
        return x;
    }
    float scaled = x * bands;
    float cell   = floor(scaled);
    float f      = fract(scaled);
    float w      = clamp(blend, 0.002, 1.0) * 0.5;
    return (cell + smootherstep(0.5 - w, 0.5 + w, f)) / bands;
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

    // Flowing noise, sampled per pixel in world space and marched downward
    // through the field so it streams up the flame.
    vec3  flowPos = vec3(fs_Pos) * COLOR_SCALE
                  + vec3(0.0, -u_RoilSpeed * u_Time, 0.0);
    float flow    = fbm(flowPos);

    // The dominant term is position along the flame. Fire is fed at its root, so
    // the base burns white-hot and everything cools on the way up until the
    // crown is charred. Gain above 0.5 drives the two ends apart, which widens
    // the white core at the base and deepens the char at the tip.
    float heat = gain(0.68, 1.0 - fs_Height);

    // Warp that gradient with the flowing noise. Displacing the coordinate
    // rather than the color is what makes whole tongues of one band push up into
    // the next, the way the boundaries in real fire wander and reconnect.
    heat += u_Flow * (flow - 0.5) * 2.0;

    // Stay correlated with the vertex shader's displacement: a tongue that has
    // pushed further up has travelled further from the fuel, so it reads cooler
    // than the body it came from.
    heat -= 0.24 * (fs_Disp - 0.5);

    // Fold in the fine FBM layer on its own, which mottles the flame at a finer
    // scale than the low-frequency sway reaches.
    heat *= mix(0.84, 1.12, fs_Fbm);

    // The surge cycle flashes the whole flame hotter as it swells.
    heat += 0.16 * fs_Pulse;

    // Finally the heat slider biases the whole ramp hotter or cooler.
    heat = bias(clamp(u_Heat, 0.05, 0.95), clamp(heat, 0.0, 1.0));

    // Quantize into bands for the painted look of stylized fire. The warp above
    // has already bent the boundaries into organic shapes, so this only decides
    // how hard the steps between them read.
    heat = posterize(heat, u_Bands, u_BandBlend);

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
