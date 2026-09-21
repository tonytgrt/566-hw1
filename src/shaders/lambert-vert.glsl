#version 300 es

//This is a vertex shader. While it is called a "shader" due to outdated conventions, this file
//is used to apply matrix transformations to the arrays of vertex data passed to it.
//Since this code is run on your GPU, each vertex is transformed simultaneously.
//If it were run on your CPU, each vertex would have to be processed in a FOR loop, one at a time.
//This simultaneous transformation allows your program to run much faster, especially when rendering
//geometry with millions of vertices.

uniform mat4 u_Model;       // The matrix that defines the transformation of the
                            // object we're rendering. In this assignment,
                            // this will be the result of traversing your scene graph.

uniform mat4 u_ModelInvTr;  // The inverse transpose of the model matrix.
                            // This allows us to transform the object's normals properly
                            // if the object has been non-uniformly scaled.

uniform mat4 u_ViewProj;    // The matrix that defines the camera's transformation.
                            // We've written a static matrix for you to use for HW2,
                            // but in HW3 you'll have to generate one yourself

uniform float u_Time;       // Seconds elapsed since the program started. Drives every
                            // animated term below so the fireball roils continuously.

in vec4 vs_Pos;             // The array of vertex positions passed to the shader

in vec4 vs_Nor;             // The array of vertex normals passed to the shader

in vec4 vs_Col;             // The array of vertex colors passed to the shader.

out vec4 fs_Nor;            // The array of normals that has been transformed by u_ModelInvTr. This is implicitly passed to the fragment shader.
out vec4 fs_LightVec;       // The direction in which our virtual light lies, relative to each vertex. This is implicitly passed to the fragment shader.
out vec4 fs_Col;            // The color of each vertex. This is implicitly passed to the fragment shader.

out float fs_Disp;          // Total displacement applied to this vertex, remapped to roughly [0, 1].
                            // The fragment shader uses this to drive the fireball's color gradient.
out float fs_Fbm;           // Just the high-frequency FBM layer, for finer color detail.
out float fs_Height;        // 0 at the root of the flame, 1 at the crown. The fragment shader's
                            // gradient runs along this: white-hot base, charred tip.
out float fs_Pulse;         // [0, 1] phase of the explosion cycle, so the fragment shader can
                            // flash the color in step with the geometry's swell.
out vec4 fs_Pos;            // The displaced world-space position, used for the view vector and
                            // for varying the flicker across the surface.

const vec4 lightPos = vec4(5, 5, 3, 1); //The position of our virtual light, which is used to compute the shading of
                                        //the geometry in the fragment shader.

// ---------------------------------------------------------------------------
// Tunable art direction. Every one of these is driven by a dat.GUI slider in
// main.ts;
// ---------------------------------------------------------------------------
uniform float u_LowFreqAmp;    // high amplitude, low frequency: the overall blobby silhouette
uniform float u_LowFreqScale;  // spatial frequency of the sinusoidal lobes
uniform float u_FbmAmp;        // low amplitude, high frequency: the crusty surface detail
uniform float u_FbmScale;      // spatial frequency of the FBM
uniform int   u_Octaves;       // how many FBM octaves are summed
uniform float u_RoilSpeed;     // how quickly the surface churns
uniform float u_PulsePeriod;   // seconds per "breath"/explosion cycle
uniform float u_PulseStrength; // 0 holds the ball steady, 1 is the full swell
uniform float u_FlameHeight;   // how far the sphere is stretched vertically into a flame
uniform float u_Taper;         // how far the crown is drawn in relative to the root

const int   MAX_OCTAVES = 8;    // hard bound so the FBM loop always terminates
const float MIN_TAPER   = 0.05; // keeps the crown from collapsing to zero width

// The offset's theoretical maximum is far larger than what its terms ever reach
// together: sampled over the sphere, offset/maxOffset only spans a narrow slice
// of [0, 1], which would leave the fragment shader's mottling stuck on one flat
// value. This expands that measured spread. Measured to hold across the sliders.
const float DISP_SPREAD = 2.6;
const float PULSE_MIN   = 0.85; // displacement multiplier at rest
const float PULSE_MAX   = 1.35; // displacement multiplier at the peak of a burst

// ---------------------------------------------------------------------------
// Toolbox functions 
// ---------------------------------------------------------------------------

// 1) Perlin's bias: pushes t toward 0 or 1 without changing its [0,1] range.
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

// 3) Sawtooth wave: a value that ramps 0 -> 1 once per period. Used as the
//    "time since the last explosion" clock so the animation loops cleanly.
float sawtooth(float x, float period)
{
    return fract(x / period);
}

// 4) Exponential impulse: a fast attack / slow decay spike in [0,1]. Combined
//    with the sawtooth it gives the fireball a repeating outward burst.
float expImpulse(float x, float k)
{
    float h = k * x;
    return h * exp(1.0 - h);
}

// 5) Smootherstep (Perlin's quintic ease): C2-continuous ease-in/ease-out.
float smootherstep(float a, float b, float t)
{
    t = clamp((t - a) / (b - a), 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// ---------------------------------------------------------------------------
// 3D value noise + fractal Brownian motion
// ---------------------------------------------------------------------------

float hash31(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Value noise: hash the 8 lattice corners and trilinearly interpolate them
// using a quintic falloff so the result has continuous derivatives.
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

// Fractal Brownian motion: summed octaves of noise at doubling frequency and
// halving amplitude. Returns roughly [0, 1].
float fbm(vec3 p)
{
    float sum  = 0.0;
    float amp  = 0.5;
    float freq = 1.0;
    float norm = 0.0;


    for (int i = 0; i < MAX_OCTAVES; ++i)
    {
        if (i >= u_Octaves) break;

        sum  += amp * valueNoise(p * freq + float(i) * 17.3);
        norm += amp;
        amp  *= 0.5;
        freq *= 2.0;
    }

    return norm > 0.0 ? sum / norm : 0.5;
}

// ---------------------------------------------------------------------------
// Displacement
// ---------------------------------------------------------------------------

// Low-frequency, high-amplitude term: f(x, y, z) = h.
// A product of three sinusoids at incommensurate frequencies gives large,
// slowly-tumbling lobes that break up the sphere's silhouette, plus a vertical
// ripple that reads as heat rising through the ball.
float lowFrequencyHeight(vec3 p, float t)
{
    vec3 q = p * u_LowFreqScale;

    float lobes  = sin(1.5 * q.x + 0.90 * t)
                 * sin(1.9 * q.y - 0.70 * t + 1.7)
                 * sin(1.3 * q.z + 0.55 * t + 3.1);

    float ripple = sin(2.4 * q.y + 1.60 * t);

    // A slower, fatter wave keeps the ball from ever looking perfectly round.
    float swell  = sin(0.9 * q.x - 0.4 * t) * cos(1.1 * q.z + 0.6 * t);

    return 0.62 * lobes + 0.20 * ripple + 0.18 * swell;
}

// Looping "explosion" clock, normalized to [0, 1]: 0 at rest, 1 at the peak of
// a burst. The geometry swells with it and the fragment shader flashes with it.
float pulsePhase(float t)
{
    // Ramps 0 -> 1 once per period. max() keeps the period away from 0, which
    // would make the sawtooth NaN.
    float cycle = sawtooth(t, max(0.01, u_PulsePeriod));

    // Fading the impulse out over the tail of the cycle guarantees it is back
    // at exactly 0 when the sawtooth wraps, so the loop has no visible pop.
    float burst = expImpulse(cycle, 6.0) * (1.0 - smootherstep(0.75, 1.0, cycle));

    return smootherstep(0.0, 1.0, burst);
}

// ---------------------------------------------------------------------------
// Flame shape
//
// Fire does not bulge in every direction the way a liquid blob does, so the
// sphere is first bent into a teardrop and then displaced along +Y only. The
// root of a flame is anchored and smooth; everything that moves, moves upward.
// ---------------------------------------------------------------------------

// Normalized position along the flame: 0 at the root, 1 at the crown.
float flameParam(vec3 dir)
{
    return 0.5 * (dir.y + 1.0);
}

// Bend the unit sphere into a teardrop: wide and round at the root, drawn in
// toward the crown, and stretched vertically. This is the static silhouette the
// displacement is then layered on top of.
vec3 flameShape(vec3 dir, float radius)
{
    float u = flameParam(dir);

    // Easing the taper in above the waist keeps the root a full round dome and
    // pulls the width in only over the upper half.
    float taper = mix(1.0, max(MIN_TAPER, 1.0 - u_Taper), smootherstep(0.20, 1.0, u));

    return radius * vec3(dir.x * taper, dir.y * u_FlameHeight, dir.z * taper);
}

// The displacement, which runs along +Y and nothing else. Writes the raw noise
// layers out through `outSway` / `outDetail` for the fragment shader's mottling.
vec3 flameOffset(vec3 dir, float radius, float t, out float outSway, out float outDetail)
{
    float u    = flameParam(dir);
    vec3  base = flameShape(dir, radius);

    float envelope = mix(PULSE_MIN, PULSE_MAX, pulsePhase(t));

    // At strength 0 the envelope flattens to 1.0 and the flame stops surging.
    float pulse = mix(1.0, envelope, u_PulseStrength);

    // The root is anchored and the crown is free, so the whole field is scaled
    // by height. This is what keeps the base a clean dome while the top frays.
    float rise = smootherstep(0.05, 0.95, u);

    outSway = lowFrequencyHeight(base, t);

    // Marching the sample point downward through the noise field makes the
    // detail appear to stream up the flame, the way real fire does.
    vec3  noisePos = base * u_FbmScale + vec3(0.0, -u_RoilSpeed * t, 0.0);
    float raw      = fbm(noisePos);

    // Gain below 0.5 softens the noise into rounded masses; bias then pulls the
    // midtones down so what survives reads as licks rather than lumps.
    outDetail = bias(0.42, gain(0.38, raw));

    // Flames reach upward, never down, so the tongues are a strictly positive
    // term confined to the crown. Sharpening it hard is what separates them into
    // distinct licks instead of one rolling bulge.
    float licks = bias(0.28, outDetail) * smootherstep(0.45, 1.0, u);

    float h = u_LowFreqAmp * outSway * rise
            + u_FbmAmp * (outDetail * 2.0 - 1.0) * rise
            + u_FbmAmp * 3.0 * licks;

    return vec3(0.0, h * pulse * radius, 0.0);
}

// Where a point in direction `dir` ends up. Used for the neighbour samples the
// recomputed normal is differenced from.
vec3 flamePoint(vec3 dir, float radius, float t)
{
    float sway, detail;
    return flameShape(dir, radius) + flameOffset(dir, radius, t, sway, detail);
}

void main()
{
    fs_Col = vs_Col;                         // Pass the vertex colors to the fragment shader for interpolation

    // The icosphere is centered at the origin, so the surface normal is simply
    // the normalized position, and the radius is its length.
    vec3  dir    = normalize(vec3(vs_Nor));
    float radius = length(vec3(vs_Pos));

    float sway, detail;
    vec3  offset    = flameOffset(dir, radius, u_Time, sway, detail);
    vec3  displaced = flameShape(dir, radius) + offset;

    // Hand the displacement to the fragment shader, remapped to ~[0, 1], so the
    // color stays correlated with the geometry.
    // max() guards the case where both amplitude sliders are dialed to 0.
    float maxOffset = max(1e-4, (u_LowFreqAmp + u_FbmAmp) * PULSE_MAX * radius);
    fs_Disp  = clamp(0.5 + 0.5 * DISP_SPREAD * offset.y / maxOffset, 0.0, 1.0);
    fs_Fbm   = detail;
    fs_Pulse = u_PulseStrength * pulsePhase(u_Time);

    // How far up the flame this vertex sits, which is what drives the fragment
    // shader's gradient: hottest at the root, charred at the crown.
    fs_Height = clamp(0.5 + 0.5 * displaced.y / max(1e-4, radius * u_FlameHeight), 0.0, 1.0);

    // Recompute the normal by finite differencing across the displaced surface.
    // Without this the lighting still reads as a smooth sphere and none of the
    // displacement is visible in the shading.
    vec3 up        = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent   = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    // Roughly the edge length of the icosphere at the default tesselation, so
    // the difference tracks features the mesh can actually resolve.
    const float eps = 0.02;
    vec3 pt = flamePoint(normalize(dir + tangent   * eps), radius, u_Time);
    vec3 pb = flamePoint(normalize(dir + bitangent * eps), radius, u_Time);
    vec3 displacedNor = normalize(cross(pt - displaced, pb - displaced));

    mat3 invTranspose = mat3(u_ModelInvTr);
    fs_Nor = vec4(invTranspose * displacedNor, 0);          // Pass the vertex normals to the fragment shader for interpolation.
                                                            // Transform the geometry's normals by the inverse transpose of the
                                                            // model matrix. This is necessary to ensure the normals remain
                                                            // perpendicular to the surface after the surface is transformed by
                                                            // the model matrix.


    vec4 modelposition = u_Model * vec4(displaced, 1.0);   // Temporarily store the transformed vertex positions for use below

    fs_Pos = modelposition;                  // The fragment shader needs the world-space position for
                                             // its view vector and for the spatial flicker phase

    fs_LightVec = lightPos - modelposition;  // Compute the direction in which the light source lies

    gl_Position = u_ViewProj * modelposition;// gl_Position is a built-in variable of OpenGL which is
                                             // used to render the final positions of the geometry's vertices
}
