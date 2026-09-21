import CameraControls from '3d-view-controls';
import {vec3, mat4} from 'gl-matrix';

class Camera {
  controls: any;
  projectionMatrix: mat4 = mat4.create();
  viewMatrix: mat4 = mat4.create();
  fovy: number = 45;
  aspectRatio: number = 1;
  near: number = 0.1;
  far: number = 1000;
  position: vec3 = vec3.create();
  direction: vec3 = vec3.create();
  target: vec3 = vec3.create();
  up: vec3 = vec3.create();

  // Last line the debug readout printed, so an unchanged camera stays quiet.
  private lastSpecs: string = '';

  // `up` is what rolls the camera. Without it the controls default to world up,
  // which pins the flame's axis to screen-vertical no matter where `position`
  // is, because the flame is rotationally symmetric about world Y.
  constructor(position: vec3, target: vec3, up: vec3 = vec3.fromValues(0, 1, 0)) {
    this.controls = CameraControls(document.getElementById('canvas'), {
      eye: position,
      center: target,
      up: up,
    });
    vec3.add(this.target, this.position, this.direction);
    mat4.lookAt(this.viewMatrix, this.controls.eye, this.controls.center, this.controls.up);
  }

  setAspectRatio(aspectRatio: number) {
    this.aspectRatio = aspectRatio;
  }

  updateProjectionMatrix() {
    mat4.perspective(this.projectionMatrix, this.fovy, this.aspectRatio, this.near, this.far);
  }

  update() {
    this.controls.tick();
    vec3.add(this.target, this.position, this.direction);
    mat4.lookAt(this.viewMatrix, this.controls.eye, this.controls.center, this.controls.up);
    this.logSpecs();
  }

  // Debug readout of the live camera state, in a form that can be pasted
  // straight back into the Camera constructor in main.ts.
  //
  // This runs every frame but only prints when something actually moved. A
  // genuine 60 Hz log buries the value you are trying to read the instant you
  // stop dragging, and stalls the browser once the console has a few thousand
  // lines in it. Drop the `if` below to make it unconditional.
  logSpecs() {
    const v = (a: vec3) => `[${a[0].toFixed(2)}, ${a[1].toFixed(2)}, ${a[2].toFixed(2)}]`;

    const eye: vec3 = this.controls.eye;
    const center: vec3 = this.controls.center;
    const up: vec3 = this.controls.up;

    // mat4.perspective takes radians, but `fovy` is set to 45, so the effective
    // vertical field of view is 45 radians wrapped into range, not 45 degrees.
    const effectiveFovy = ((this.fovy % (2 * Math.PI)) * 180) / Math.PI;

    const specs = `camera  eye ${v(eye)}  center ${v(center)}  up ${v(up)}` +
                  `  dist ${vec3.distance(eye, center).toFixed(2)}` +
                  `  fovy ${this.fovy} (${effectiveFovy.toFixed(1)} deg effective)` +
                  `  aspect ${this.aspectRatio.toFixed(3)}` +
                  `  near ${this.near}  far ${this.far}`;

    if (specs !== this.lastSpecs) {
      console.log(specs);
      this.lastSpecs = specs;
    }
  }
};

export default Camera;
