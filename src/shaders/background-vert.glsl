#version 300 es

// The background is drawn as a single full-screen quad. The Square's vertices
// are already in normalized device coordinates, so they go straight to
// gl_Position with no camera transform at all: this geometry lives in screen
// space, and the fragment shader draws the whole scene procedurally from the
// interpolated quad coordinate.

in vec4 vs_Pos;      // The quad's corners, already at the edges of the screen

out vec2 fs_Pos;     // Screen position in [-1, 1], before any aspect correction

void main()
{
    fs_Pos = vs_Pos.xy;

    // No u_Model / u_ViewProj: writing the vertex straight through is what
    // pins this quad to the screen while the camera orbits the flame.
    gl_Position = vs_Pos;
}
