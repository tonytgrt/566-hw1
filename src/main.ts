import {vec3} from 'gl-matrix';
import Stats from 'stats-js';
import * as DAT from 'dat.gui';
import Icosphere from './geometry/Icosphere';
import Square from './geometry/Square';
import OpenGLRenderer from './rendering/gl/OpenGLRenderer';
import Camera from './Camera';
import {setGL} from './globals';
import ShaderProgram, {Shader, FireballParams} from './rendering/gl/ShaderProgram';

import lambertVertSource from './shaders/lambert-vert.glsl?raw';
import lambertFragSource from './shaders/lambert-frag.glsl?raw';

// The art-directed defaults. `Reset Defaults` copies these back over `controls`,
// and they're kept separate so the button always has a pristine copy to restore.
const defaults: FireballParams & {tesselations: number} = {
  tesselations: 5,
  displacement: 0.38,   // amplitude of the low-frequency sinusoidal lobes
  lobeScale: 1.0,       // frequency of those lobes
  detail: 0.13,         // amplitude of the high-frequency FBM crust
  detailScale: 2.6,     // frequency of that FBM
  octaves: 4,           // how many FBM octaves get summed
  roilSpeed: 0.85,      // how fast the surface churns
  pulsePeriod: 4.0,     // seconds per explosion/breath cycle
  pulseStrength: 1.0,   // 0 holds the ball steady, 1 is the full swell
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

// Restore the art-directed defaults, then push the new values back into the
// sliders so the GUI doesn't keep showing the old ones.
function resetDefaults() {
  Object.assign(controls, defaults);
  for (const controller of gui.__controllers) {
    controller.updateDisplay();
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

  // Add controls to the gui
  gui = new DAT.GUI();
  gui.add(controls, 'tesselations', 0, 8).step(1);
  gui.add(controls, 'displacement', 0.0, 0.8).step(0.01).name('displacement');
  gui.add(controls, 'lobeScale', 0.2, 4.0).step(0.05).name('lobe scale');
  gui.add(controls, 'detail', 0.0, 0.4).step(0.005).name('detail amount');
  gui.add(controls, 'detailScale', 0.5, 8.0).step(0.1).name('detail scale');
  gui.add(controls, 'octaves', 0, 8).step(1).name('fbm octaves');
  gui.add(controls, 'roilSpeed', 0.0, 3.0).step(0.05).name('roil speed');
  gui.add(controls, 'pulsePeriod', 0.5, 12.0).step(0.1).name('pulse period');
  gui.add(controls, 'pulseStrength', 0.0, 1.0).step(0.01).name('pulse strength');
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

  const camera = new Camera(vec3.fromValues(0, 0, 5), vec3.fromValues(0, 0, 0));

  const renderer = new OpenGLRenderer(canvas);
  renderer.setClearColor(0.2, 0.2, 0.2, 1);
  gl.enable(gl.DEPTH_TEST);

  const lambert = new ShaderProgram([
    new Shader(gl.VERTEX_SHADER, lambertVertSource),
    new Shader(gl.FRAGMENT_SHADER, lambertFragSource),
  ]);

  const startTime = performance.now();

  // This function will be called every frame
  function tick() {
    camera.update();
    // Seconds since the program started, passed to the shaders so their
    // displacement and color animate over time.
    lambert.setTime((performance.now() - startTime) * 0.001);
    lambert.setFireballParams(controls);
    stats.begin();
    gl.viewport(0, 0, window.innerWidth, window.innerHeight);
    renderer.clear();
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
