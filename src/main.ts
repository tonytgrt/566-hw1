import {vec3} from 'gl-matrix';
import Stats from 'stats-js';
import * as DAT from 'dat.gui';
import Icosphere from './geometry/Icosphere';
import Square from './geometry/Square';
import OpenGLRenderer from './rendering/gl/OpenGLRenderer';
import Camera from './Camera';
import {setGL} from './globals';
import ShaderProgram, {Shader, FireballParams, BackgroundParams} from './rendering/gl/ShaderProgram';

import lambertVertSource from './shaders/lambert-vert.glsl?raw';
import lambertFragSource from './shaders/lambert-frag.glsl?raw';
import backgroundVertSource from './shaders/background-vert.glsl?raw';
import backgroundFragSource from './shaders/background-frag.glsl?raw';

// The art-directed defaults. `Reset Defaults` copies these back over `controls`,
// and they're kept separate so the button always has a pristine copy to restore.
const defaults: FireballParams & BackgroundParams & {tesselations: number} = {
  tesselations: 5,
  displacement: 0.18,   // amplitude of the low-frequency upward sway
  lobeScale: 1.2,       // frequency of that sway
  detail: 0.37,         // amplitude of the high-frequency FBM, which forms the licks
  detailScale: 6,     // frequency of that FBM
  octaves: 5,           // how many FBM octaves get summed
  roilSpeed: 1.1,       // how fast the flame streams upward
  pulsePeriod: 4.7,     // seconds per surge cycle
  pulseStrength: 0.59,  // 0 holds the flame steady, 1 is the full surge
  heat: 0.5,            // 0.5 is the gradient as authored, higher runs hotter
  flow: 0.42,           // how strongly flowing noise warps the color gradient
  bandBlend: 0.79,      // 0 gives hard cel band edges, 1 an unbroken gradient
  flameHeight: 1.5,     // vertical stretch from sphere to flame
  taper: 0.12,          // how far the crown is drawn in relative to the root
  bands: 12,             // quantized color bands; below 2 the gradient is smooth
  horizon: -0.07,        // where the planet's limb crosses the centre of the screen
  atmosphere: 0.028,    // thickness of the atmospheric halo above the limb
};

// Define an object with application parameters and button callbacks
// This will be referred to by dat.GUI's functions that add GUI elements.
const controls = {
  ...defaults,
  'Load Scene': loadScene, // A function pointer, essentially
  'Reset Defaults': resetDefaults,
};

let icosphere: Icosphere;
let square: Square;
let prevTesselations: number = 5;
let gui: DAT.GUI;

// Every slider we build, recorded so `Reset Defaults` can push the restored
// values back into the widgets. Collected as they are created rather than read
// off dat.GUI's `__controllers`, which holds only the panel's top level and
// would silently skip everything nested inside a folder.
const sliders: DAT.GUIController[] = [];

// Add one slider to a folder and remember it. `prop` is keyed off `controls`,
// so a mistyped name is a compile error rather than a silently dead control.
function addSlider(folder: DAT.GUI, prop: keyof typeof controls, min: number,
                   max: number, step: number, label: string) {
  sliders.push(folder.add(controls, prop, min, max).step(step).name(label));
}

// Restore the art-directed defaults, then push the new values back into the
// sliders so the GUI doesn't keep showing the old ones.
function resetDefaults() {
  Object.assign(controls, defaults);
  for (const slider of sliders) {
    slider.updateDisplay();
  }
}

function loadScene() {
  icosphere = new Icosphere(vec3.fromValues(0, 0, 0), 1, controls.tesselations);
  icosphere.create();
  square = new Square(vec3.fromValues(0, 0, 0));
  square.create();
}

function main() {
  // Initial display for framerate
  const stats = Stats();
  stats.setMode(0);
  stats.domElement.style.position = 'absolute';
  stats.domElement.style.left = '0px';
  stats.domElement.style.top = '0px';
  document.body.appendChild(stats.domElement);

  // Add controls to the gui, grouped by what each set actually affects. The
  // folders open by default so nothing is hidden on load; collapsing them is
  // the point of the grouping.
  gui = new DAT.GUI();

  // The silhouette before any noise touches it.
  const shapeFolder = gui.addFolder('Flame shape');
  addSlider(shapeFolder, 'tesselations', 0, 8, 1, 'tesselations');
  addSlider(shapeFolder, 'flameHeight', 1.0, 2.5, 0.05, 'flame height');
  addSlider(shapeFolder, 'taper', 0.0, 0.8, 0.01, 'taper');
  shapeFolder.open();

  // The vertex shader's two noise layers: the low-frequency sway and the
  // high-frequency FBM that frays the crown into tongues.
  const displacementFolder = gui.addFolder('Displacement');
  addSlider(displacementFolder, 'displacement', 0.0, 0.8, 0.01, 'sway amount');
  addSlider(displacementFolder, 'lobeScale', 0.2, 4.0, 0.05, 'sway scale');
  addSlider(displacementFolder, 'detail', 0.0, 0.6, 0.005, 'detail amount');
  addSlider(displacementFolder, 'detailScale', 0.5, 8.0, 0.1, 'detail scale');
  addSlider(displacementFolder, 'octaves', 0, 8, 1, 'fbm octaves');
  displacementFolder.open();

  // Everything driven by the time uniform.
  const animationFolder = gui.addFolder('Animation');
  addSlider(animationFolder, 'roilSpeed', 0.0, 3.0, 0.05, 'roil speed');
  addSlider(animationFolder, 'pulsePeriod', 0.5, 12.0, 0.1, 'pulse period');
  addSlider(animationFolder, 'pulseStrength', 0.0, 1.0, 0.01, 'pulse strength');
  animationFolder.open();

  // The fragment shader's gradient and banding.
  const colorFolder = gui.addFolder('Color');
  addSlider(colorFolder, 'heat', 0.2, 0.8, 0.01, 'heat');
  addSlider(colorFolder, 'flow', 0.0, 0.6, 0.01, 'color flow');
  addSlider(colorFolder, 'bands', 0, 12, 1, 'color bands');
  addSlider(colorFolder, 'bandBlend', 0.0, 1.0, 0.01, 'band blend');
  colorFolder.open();

  // The procedural planet behind the flame.
  const backgroundFolder = gui.addFolder('Background');
  addSlider(backgroundFolder, 'horizon', -0.6, 0.8, 0.01, 'horizon');
  addSlider(backgroundFolder, 'atmosphere', 0.005, 0.12, 0.001, 'atmosphere');
  backgroundFolder.open();

  // Left at the root so they stay reachable with every folder collapsed.
  gui.add(controls, 'Load Scene');
  gui.add(controls, 'Reset Defaults');

  // get canvas and webgl context
  const canvas = <HTMLCanvasElement> document.getElementById('canvas');
  const gl = <WebGL2RenderingContext> canvas.getContext('webgl2');
  if (!gl) {
    alert('WebGL 2 not supported!');
  }
  // `setGL` is a function imported above which sets the value of `gl` in the `globals.ts` module.
  // Later, we can import `gl` from `globals.ts` to access it
  setGL(gl);

  // Initial call to load scene
  loadScene();

  // Eye, target and up, all three read off the console readout in Camera.ts.
  // The up vector is the one that tilts the flame; without it the view comes
  // back upright however the eye is placed.
  const camera = new Camera(vec3.fromValues(4.48, 1.01, -1.98),
                            vec3.fromValues(0, 0, 0),
                            vec3.fromValues(-0.12, 0.69, -0.72));

  const renderer = new OpenGLRenderer(canvas);
  // The background covers every pixel, so this only shows if it fails to draw.
  renderer.setClearColor(0.004, 0.006, 0.014, 1);
  gl.enable(gl.DEPTH_TEST);

  const lambert = new ShaderProgram([
    new Shader(gl.VERTEX_SHADER, lambertVertSource),
    new Shader(gl.FRAGMENT_SHADER, lambertFragSource),
  ]);

  const background = new ShaderProgram([
    new Shader(gl.VERTEX_SHADER, backgroundVertSource),
    new Shader(gl.FRAGMENT_SHADER, backgroundFragSource),
  ]);

  const startTime = performance.now();

  // This function will be called every frame
  function tick() {
    camera.update();
    // Seconds since the program started, passed to the shaders so their
    // displacement and color animate over time.
    const time = (performance.now() - startTime) * 0.001;
    lambert.setTime(time);
    lambert.setFireballParams(controls);
    stats.begin();
    gl.viewport(0, 0, window.innerWidth, window.innerHeight);
    renderer.clear();

    // The background is a screen-space quad drawn before anything else. With
    // the depth test off it neither tests nor writes depth, so it can never
    // occlude the flame no matter where the camera is.
    gl.disable(gl.DEPTH_TEST);
    background.setTime(time);
    background.setDimensions(canvas.width, canvas.height);
    background.setBackgroundParams(controls);
    background.draw(square);
    gl.enable(gl.DEPTH_TEST);
    if(controls.tesselations != prevTesselations)
    {
      prevTesselations = controls.tesselations;
      icosphere = new Icosphere(vec3.fromValues(0, 0, 0), 1, prevTesselations);
      icosphere.create();
    }
    renderer.render(camera, lambert, [
      icosphere,
      // square,
    ]);
    stats.end();

    // Tell the browser to call `tick` again whenever it renders a new frame
    requestAnimationFrame(tick);
  }

  window.addEventListener('resize', function() {
    renderer.setSize(window.innerWidth, window.innerHeight);
    camera.setAspectRatio(window.innerWidth / window.innerHeight);
    camera.updateProjectionMatrix();
  }, false);

  renderer.setSize(window.innerWidth, window.innerHeight);
  camera.setAspectRatio(window.innerWidth / window.innerHeight);
  camera.updateProjectionMatrix();

  // Start the render loop
  tick();
}

main();
