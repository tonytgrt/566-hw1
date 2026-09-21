#version 300 es

// Procedural background: an Earth-sized sphere filling the lower part of the
// frame, its atmosphere fading up into starfield. Nothing here is textured or
// modelled - the planet is a single circle whose centre sits far below the
// screen, shaded as a sphere and surfaced with noise.
precision highp float;

uniform float u_Time;        // Seconds since start, for cloud drift and star twinkle.
uniform vec2  u_Dimensions;  // Canvas size in pixels, used only for the aspect ratio.
uniform float u_Horizon;     // Screen height at which the limb crosses the centre line.
uniform float u_Atmosphere;  // Thickness of the atmospheric halo, as a fraction of the radius.

in vec2 fs_Pos;

out vec4 out_Col;

// ---------------------------------------------------------------------------
// Scene constants
// ---------------------------------------------------------------------------

// Far larger than the screen, which is the whole trick: only a shallow arc of
// the circle is ever visible, so it reads as the limb of something enormous
// rather than as a ball sitting in frame.
const float EARTH_RADIUS = 3.2;

// A perfectly level horizon reads as a flat backdrop. A few degrees of tilt is
// what makes it read as a planet seen from orbit.
const float TILT = -0.17;

// Off the top-right corner, matching the glow drawn at the same place below.
const vec3 SUN_DIR = normalize(vec3(0.55, 0.62, 0.56));

const vec3 SPACE         = vec3(0.004, 0.006, 0.014);
const vec3 OCEAN_DEEP    = vec3(0.008, 0.028, 0.098);
const vec3 OCEAN_SHALLOW = vec3(0.034, 0.125, 0.305);
const vec3 LAND          = vec3(0.115, 0.120, 0.105);
const vec3 CLOUD         = vec3(0.920, 0.940, 0.970);
const vec3 SKY           = vec3(0.350, 0.620, 1.000); // atmospheric scattering tint

// ---------------------------------------------------------------------------
// Noise. GLSL has no include mechanism, so this is the same value-noise
// construction the other two shaders use, with a 2D hash added for the stars.
// ---------------------------------------------------------------------------

float hash31(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float hash21(vec2 p)
{
    vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
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

float fbm(vec3 p, int octaves)
{
    float sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0;
    for (int i = 0; i < 6; ++i)
    {
        if (i >= octaves) break;
        sum  += amp * valueNoise(p * freq + float(i) * 17.3);
        norm += amp;
        amp  *= 0.5;
        freq *= 2.0;
    }
    return sum / norm;
}

// One star per grid cell at most, placed at a hashed position inside it. Most
// cells are left empty, which is what keeps the field sparse and irregular
// rather than looking like a dot screen.
float starField(vec2 p)
{
    vec2  cell = floor(p);
    vec2  f    = fract(p);
    float h    = hash21(cell);

    if (h < 0.90) {
        return 0.0;
    }

    vec2  pos = vec2(hash21(cell + 11.3), hash21(cell + 27.7));
    float mag = (h - 0.90) / 0.10;

    // Slow, per-star-offset twinkle.
    float twinkle = 0.7 + 0.3 * sin(u_Time * 1.7 + h * 63.0);

    return mag * twinkle * smoothstep(0.07, 0.0, length(f - pos));
}

void main()
{
    // Aspect-correct screen coordinates: y stays in [-1, 1] and x widens with
    // the canvas, so the planet stays circular at any window shape.
    vec2 p = fs_Pos;
    p.x *= u_Dimensions.x / max(1.0, u_Dimensions.y);

    // Tilt the scene so the limb runs diagonally across the frame.
    float ct = cos(TILT), st = sin(TILT);
    vec2  q  = vec2(p.x * ct - p.y * st, p.x * st + p.y * ct);

    vec2  center = vec2(0.0, u_Horizon - EARTH_RADIUS);
    vec2  toward = q - center;
    float dist   = length(toward);
    float t      = dist / EARTH_RADIUS;   // exactly 1.0 on the limb

    // ---- space ------------------------------------------------------------
    vec3 color = SPACE;
    color += vec3(1.0, 0.97, 0.93) * starField(q * 28.0);

    // A distant sun just off the top-right corner. It is the same direction
    // that lights the planet, so the whole frame agrees on where the light is.
    float sunDist = length(p - vec2(1.35, 0.78));
    color += vec3(1.0, 0.95, 0.88) * 0.16 / (1.0 + 26.0 * sunDist * sunDist);

    // ---- atmosphere -------------------------------------------------------
    // Outside the disc the air thins exponentially into vacuum. This is the
    // band that blends the planet into the black at the top of the frame.
    float halo = clamp(exp(-(dist - EARTH_RADIUS)
                           / max(0.001, u_Atmosphere * EARTH_RADIUS)), 0.0, 1.0);

    // Only the sunlit side of the limb scatters, so the halo fades out around
    // the unlit edge instead of ringing the planet evenly.
    vec2  limbDir   = toward / max(1e-4, dist);
    float haloLight = smoothstep(-0.45, 0.90, dot(vec3(limbDir, 0.0), SUN_DIR));

    color += SKY * halo * haloLight * 0.9;

    // ---- planet surface ---------------------------------------------------
    // Reconstruct the sphere's normal from the disc coordinate, which is what
    // lets the surface be shaded and textured as a sphere rather than a circle.
    vec2  uv = toward / EARTH_RADIUS;
    float z  = sqrt(max(0.0, 1.0 - min(1.0, dot(uv, uv))));
    vec3  n  = vec3(uv, z);

    // Turn the lookup slowly about the pole so the planet rotates under us.
    float a  = u_Time * 0.012;
    float ca = cos(a), sa = sin(a);
    vec3  sp = vec3(n.x * ca + n.z * sa, n.y, -n.x * sa + n.z * ca);

    float continents = fbm(sp * 1.8, 4);
    vec3  surface    = mix(OCEAN_DEEP, OCEAN_SHALLOW, smoothstep(0.30, 0.56, continents));
    surface = mix(surface, LAND, smoothstep(0.54, 0.62, continents));

    // Clouds are a second, finer field drifting at its own rate, so they slide
    // over the continents instead of being locked to them. Two layers at
    // different scales keep the banks from reading as one blurry blob.
    vec3  cloudPos = sp * 6.5 + vec3(0.0, 0.0, u_Time * 0.02);
    float clouds   = fbm(cloudPos, 5) * 0.72 + fbm(cloudPos * 2.7, 4) * 0.28;
    surface = mix(surface, CLOUD, smoothstep(0.47, 0.66, clouds) * 0.88);

    // Wrapped diffuse. A hard terminator would put half the disc in shadow; the
    // reference is lit from over the shoulder with the night side out of frame.
    // Kept deliberately below 1.0 at the top end: the planet is a backdrop, and
    // a brighter one would swallow the white-hot base of the flame in front.
    float light = smoothstep(-0.35, 0.85, dot(n, SUN_DIR));
    surface *= mix(0.04, 0.92, light);

    // Along the limb the line of sight passes through far more air than it does
    // looking straight down, so the last sliver of the disc washes out to blue.
    surface = mix(surface, SKY * 1.3, smoothstep(0.88, 1.0, t) * 0.8 * light);

    // ---- composite --------------------------------------------------------
    // fwidth gives the edge a one-pixel blend at any resolution, so the limb
    // does not alias into a staircase.
    float aa   = max(fwidth(t) * 1.5, 1e-5);
    float disc = smoothstep(1.0 + aa, 1.0 - aa, t);

    color = mix(color, surface, disc);

    out_Col = vec4(color, 1.0);
}
