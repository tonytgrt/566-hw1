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
out vec4 fs_Pos;            // The undisplaced model-space position, useful for further noise lookups.

const vec4 lightPos = vec4(5, 5, 3, 1); //The position of our virtual light, which is used to compute the shading of
                                        //the geometry in the fragment shader.

// ---------------------------------------------------------------------------
// Tunable art direction. Every one of these is driven by a dat.GUI slider in
// main.ts; the value in each comment is the default that "Reset Defaults"
// restores.
// ---------------------------------------------------------------------------
uniform float u_LowFreqAmp;    // 0.38 - high amplitude, low frequency: the overall blobby silhouette
uniform float u_LowFreqScale;  // 1.00 - spatial frequency of the sinusoidal lobes
uniform float u_FbmAmp;        // 0.13 - low amplitude, high frequency: the crusty surface detail
uniform float u_FbmScale;      // 2.60 - spatial frequency of the FBM
uniform int   u_Octaves;       // 4    - how many FBM octaves are summed
uniform float u_RoilSpeed;     // 0.85 - how quickly the surface churns
uniform float u_PulsePeriod;   // 4.00 - seconds per "breath"/explosion cycle
uniform float u_PulseStrength; // 1.00 - 0 holds the ball steady, 1 is the full swell

const int   MAX_OCTAVES = 8;    // hard bound so the FBM loop always terminates
const float MIN_RADIUS  = 0.15; // fraction of the base radius the surface may never go below
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

// 2) Perlin's gain: sharpens (g < 0.5) or softens (g > 0.5) the contrast around 0.5.
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

// The full height field: the sinusoidal base plus a finer FBM crust, wrapped in
// a looping pulse so the fireball repeatedly swells and settles.
// Writes the raw layers out through `outLow` / `outFbm` for the color gradient.
float surfaceHeight(vec3 dir, float t, out float outLow, out float outFbm)
{
    // Looping "explosion" clock: ramps 0 -> 1 once per period, shaped into a
    // fast burst with a slow settle. max() keeps the period away from 0, which
    // would make the sawtooth NaN.
    float cycle = sawtooth(t, max(0.01, u_PulsePeriod));

    // Fading the impulse out over the tail of the cycle guarantees it is back
    // at exactly 0 when the sawtooth wraps, so the loop has no visible pop.
    float burst = expImpulse(cycle, 6.0) * (1.0 - smootherstep(0.75, 1.0, cycle));

    float envelope = mix(PULSE_MIN, PULSE_MAX, smootherstep(0.0, 1.0, burst));

    // At strength 0 the envelope flattens to 1.0 and the ball stops breathing.
    float pulse = mix(1.0, envelope, u_PulseStrength);

    outLow = lowFrequencyHeight(dir, t);

    // Animate the FBM by marching its sample point through the noise field,
    // using time as an offset to the (x, y, z) input.
    vec3  noisePos = dir * u_FbmScale + vec3(0.0, -u_RoilSpeed * t, 0.35 * t);
    float raw      = fbm(noisePos);

    // Gain sharpens the noise into ridged, flame-like crests; bias then pulls
    // the midtones down so the crests read as thin licks rather than lumps.
    outFbm = bias(0.42, gain(0.38, raw));

    return u_LowFreqAmp * outLow * pulse + u_FbmAmp * (outFbm * 2.0 - 1.0) * pulse;
}

// Convenience overload used when computing neighbour samples for the normal.
float surfaceHeight(vec3 dir, float t)
{
    float lo, hi;
    return surfaceHeight(dir, t, lo, hi);
}

// Where a point in direction `dir` lands once `height` is applied along the
// normal. Dialing the displacement and detail sliders up together can produce a
// height more negative than the radius, which would pull the surface through
// the origin and turn the sphere inside out, so the radius is floored.
vec3 surfacePoint(vec3 dir, float radius, float height)
{
    return dir * max(MIN_RADIUS * radius, radius + height);
}

// Same thing, evaluating the height field itself. Used for the neighbour
// samples that the recomputed normal is differenced from.
vec3 displacedPoint(vec3 dir, float radius, float t)
{
    return surfacePoint(dir, radius, surfaceHeight(dir, t));
}

void main()
{
    fs_Col = vs_Col;                         // Pass the vertex colors to the fragment shader for interpolation
    fs_Pos = vs_Pos;

    // The icosphere is centered at the origin, so the surface normal is simply
    // the normalized position, and the radius is its length.
    vec3  dir    = normalize(vec3(vs_Nor));
    float radius = length(vec3(vs_Pos));

    float low, detail;
    float height = surfaceHeight(dir, u_Time, low, detail);

    // Hand the displacement to the fragment shader, remapped to ~[0, 1], so the
    // color gradient stays correlated with the geometry.
    // max() guards the case where both amplitude sliders are dialed to 0.
    float maxHeight = max(1e-4, (u_LowFreqAmp + u_FbmAmp) * PULSE_MAX);
    fs_Disp = clamp(0.5 + 0.5 * height / maxHeight, 0.0, 1.0);
    fs_Fbm  = detail;

    vec3 displaced = surfacePoint(dir, radius, height);

    // Recompute the normal by finite differencing across the displaced surface.
    // Without this the lighting still reads as a smooth sphere and none of the
    // displacement is visible in the shading.
    vec3 up        = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent   = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    // Roughly the edge length of the icosphere at the default tesselation, so
    // the difference tracks features the mesh can actually resolve.
    const float eps = 0.02;
    vec3 pt = displacedPoint(normalize(dir + tangent   * eps), radius, u_Time);
    vec3 pb = displacedPoint(normalize(dir + bitangent * eps), radius, u_Time);
    vec3 displacedNor = normalize(cross(pt - displaced, pb - displaced));

    mat3 invTranspose = mat3(u_ModelInvTr);
    fs_Nor = vec4(invTranspose * displacedNor, 0);          // Pass the vertex normals to the fragment shader for interpolation.
                                                            // Transform the geometry's normals by the inverse transpose of the
                                                            // model matrix. This is necessary to ensure the normals remain
                                                            // perpendicular to the surface after the surface is transformed by
                                                            // the model matrix.


    vec4 modelposition = u_Model * vec4(displaced, 1.0);   // Temporarily store the transformed vertex positions for use below

    fs_LightVec = lightPos - modelposition;  // Compute the direction in which the light source lies

    gl_Position = u_ViewProj * modelposition;// gl_Position is a built-in variable of OpenGL which is
                                             // used to render the final positions of the geometry's vertices
}
