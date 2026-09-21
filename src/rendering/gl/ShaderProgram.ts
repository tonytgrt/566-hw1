import {vec3, vec4, mat4} from 'gl-matrix';
import Drawable from './Drawable';
import {gl} from '../../globals';

var activeProgram: WebGLProgram = null;

// The shape parameters the fireball's vertex shader reads. `controls` in main.ts
// is the dat.GUI-backed object that satisfies this.
// The procedural background's shape parameters, read by background-frag.glsl.
export interface BackgroundParams {
  horizon: number;      // u_Horizon
  atmosphere: number;   // u_Atmosphere
}

export interface FireballParams {
  displacement: number;   // u_LowFreqAmp
  lobeScale: number;      // u_LowFreqScale
  detail: number;         // u_FbmAmp
  detailScale: number;    // u_FbmScale
  octaves: number;        // u_Octaves
  roilSpeed: number;      // u_RoilSpeed
  pulsePeriod: number;    // u_PulsePeriod
  pulseStrength: number;  // u_PulseStrength
  heat: number;           // u_Heat
  flow: number;           // u_Flow
  bandBlend: number;      // u_BandBlend
  flameHeight: number;    // u_FlameHeight
  taper: number;          // u_Taper
  bands: number;          // u_Bands
}

export class Shader {
  shader: WebGLShader;

  constructor(type: number, source: string) {
    this.shader = gl.createShader(type);
    gl.shaderSource(this.shader, source);
    gl.compileShader(this.shader);

    if (!gl.getShaderParameter(this.shader, gl.COMPILE_STATUS)) {
      throw gl.getShaderInfoLog(this.shader);
    }
  }
};

class ShaderProgram {
  prog: WebGLProgram;

  attrPos: number;
  attrNor: number;
  attrCol: number;

  unifModel: WebGLUniformLocation;
  unifModelInvTr: WebGLUniformLocation;
  unifViewProj: WebGLUniformLocation;
  unifColor: WebGLUniformLocation;
  unifTime: WebGLUniformLocation;
  unifLowFreqAmp: WebGLUniformLocation;
  unifLowFreqScale: WebGLUniformLocation;
  unifFbmAmp: WebGLUniformLocation;
  unifFbmScale: WebGLUniformLocation;
  unifOctaves: WebGLUniformLocation;
  unifRoilSpeed: WebGLUniformLocation;
  unifPulsePeriod: WebGLUniformLocation;
  unifPulseStrength: WebGLUniformLocation;
  unifHeat: WebGLUniformLocation;
  unifFlow: WebGLUniformLocation;
  unifBandBlend: WebGLUniformLocation;
  unifFlameHeight: WebGLUniformLocation;
  unifTaper: WebGLUniformLocation;
  unifBands: WebGLUniformLocation;
  unifCameraPos: WebGLUniformLocation;
  unifDimensions: WebGLUniformLocation;
  unifHorizon: WebGLUniformLocation;
  unifAtmosphere: WebGLUniformLocation;

  constructor(shaders: Array<Shader>) {
    this.prog = gl.createProgram();

    for (let shader of shaders) {
      gl.attachShader(this.prog, shader.shader);
    }
    gl.linkProgram(this.prog);
    if (!gl.getProgramParameter(this.prog, gl.LINK_STATUS)) {
      throw gl.getProgramInfoLog(this.prog);
    }

    this.attrPos = gl.getAttribLocation(this.prog, "vs_Pos");
    this.attrNor = gl.getAttribLocation(this.prog, "vs_Nor");
    this.attrCol = gl.getAttribLocation(this.prog, "vs_Col");
    this.unifModel      = gl.getUniformLocation(this.prog, "u_Model");
    this.unifModelInvTr = gl.getUniformLocation(this.prog, "u_ModelInvTr");
    this.unifViewProj   = gl.getUniformLocation(this.prog, "u_ViewProj");
    this.unifColor      = gl.getUniformLocation(this.prog, "u_Color");
    this.unifTime       = gl.getUniformLocation(this.prog, "u_Time");

    this.unifLowFreqAmp    = gl.getUniformLocation(this.prog, "u_LowFreqAmp");
    this.unifLowFreqScale  = gl.getUniformLocation(this.prog, "u_LowFreqScale");
    this.unifFbmAmp        = gl.getUniformLocation(this.prog, "u_FbmAmp");
    this.unifFbmScale      = gl.getUniformLocation(this.prog, "u_FbmScale");
    this.unifOctaves       = gl.getUniformLocation(this.prog, "u_Octaves");
    this.unifRoilSpeed     = gl.getUniformLocation(this.prog, "u_RoilSpeed");
    this.unifPulsePeriod   = gl.getUniformLocation(this.prog, "u_PulsePeriod");
    this.unifPulseStrength = gl.getUniformLocation(this.prog, "u_PulseStrength");
    this.unifHeat          = gl.getUniformLocation(this.prog, "u_Heat");
    this.unifFlow          = gl.getUniformLocation(this.prog, "u_Flow");
    this.unifBandBlend     = gl.getUniformLocation(this.prog, "u_BandBlend");
    this.unifFlameHeight   = gl.getUniformLocation(this.prog, "u_FlameHeight");
    this.unifTaper         = gl.getUniformLocation(this.prog, "u_Taper");
    this.unifBands         = gl.getUniformLocation(this.prog, "u_Bands");
    this.unifCameraPos     = gl.getUniformLocation(this.prog, "u_CameraPos");

    this.unifDimensions    = gl.getUniformLocation(this.prog, "u_Dimensions");
    this.unifHorizon       = gl.getUniformLocation(this.prog, "u_Horizon");
    this.unifAtmosphere    = gl.getUniformLocation(this.prog, "u_Atmosphere");
  }

  use() {
    if (activeProgram !== this.prog) {
      gl.useProgram(this.prog);
      activeProgram = this.prog;
    }
  }

  setModelMatrix(model: mat4) {
    this.use();
    if (this.unifModel !== -1) {
      gl.uniformMatrix4fv(this.unifModel, false, model);
    }

    if (this.unifModelInvTr !== -1) {
      let modelinvtr: mat4 = mat4.create();
      mat4.transpose(modelinvtr, model);
      mat4.invert(modelinvtr, modelinvtr);
      gl.uniformMatrix4fv(this.unifModelInvTr, false, modelinvtr);
    }
  }

  setViewProjMatrix(vp: mat4) {
    this.use();
    if (this.unifViewProj !== -1) {
      gl.uniformMatrix4fv(this.unifViewProj, false, vp);
    }
  }

  setGeometryColor(color: vec4) {
    this.use();
    if (this.unifColor !== -1) {
      gl.uniform4fv(this.unifColor, color);
    }
  }

  setTime(t: number) {
    this.use();
    if (this.unifTime !== -1) {
      gl.uniform1f(this.unifTime, t);
    }
  }

  // The dat.GUI-driven shape controls. Grouped into one call because they are
  // always set together, once per frame.
  setFireballParams(p: FireballParams) {
    this.use();
    if (this.unifLowFreqAmp !== -1) {
      gl.uniform1f(this.unifLowFreqAmp, p.displacement);
    }
    if (this.unifLowFreqScale !== -1) {
      gl.uniform1f(this.unifLowFreqScale, p.lobeScale);
    }
    if (this.unifFbmAmp !== -1) {
      gl.uniform1f(this.unifFbmAmp, p.detail);
    }
    if (this.unifFbmScale !== -1) {
      gl.uniform1f(this.unifFbmScale, p.detailScale);
    }
    if (this.unifOctaves !== -1) {
      gl.uniform1i(this.unifOctaves, p.octaves);
    }
    if (this.unifRoilSpeed !== -1) {
      gl.uniform1f(this.unifRoilSpeed, p.roilSpeed);
    }
    if (this.unifPulsePeriod !== -1) {
      gl.uniform1f(this.unifPulsePeriod, p.pulsePeriod);
    }
    if (this.unifPulseStrength !== -1) {
      gl.uniform1f(this.unifPulseStrength, p.pulseStrength);
    }
    if (this.unifHeat !== -1) {
      gl.uniform1f(this.unifHeat, p.heat);
    }
    if (this.unifFlow !== -1) {
      gl.uniform1f(this.unifFlow, p.flow);
    }
    if (this.unifBandBlend !== -1) {
      gl.uniform1f(this.unifBandBlend, p.bandBlend);
    }
    if (this.unifFlameHeight !== -1) {
      gl.uniform1f(this.unifFlameHeight, p.flameHeight);
    }
    if (this.unifTaper !== -1) {
      gl.uniform1f(this.unifTaper, p.taper);
    }
    if (this.unifBands !== -1) {
      gl.uniform1f(this.unifBands, p.bands);
    }
  }

  // The fragment shader's rim glow needs to know where the eye is.
  setCameraPos(pos: vec3) {
    this.use();
    if (this.unifCameraPos !== -1) {
      gl.uniform3fv(this.unifCameraPos, pos);
    }
  }

  // Canvas size in pixels. The background uses it for the aspect ratio, so the
  // planet stays circular whatever shape the window is.
  setDimensions(width: number, height: number) {
    this.use();
    if (this.unifDimensions !== -1) {
      gl.uniform2f(this.unifDimensions, width, height);
    }
  }

  setBackgroundParams(p: BackgroundParams) {
    this.use();
    if (this.unifHorizon !== -1) {
      gl.uniform1f(this.unifHorizon, p.horizon);
    }
    if (this.unifAtmosphere !== -1) {
      gl.uniform1f(this.unifAtmosphere, p.atmosphere);
    }
  }

  draw(d: Drawable) {
    this.use();

    if (this.attrPos != -1 && d.bindPos()) {
      gl.enableVertexAttribArray(this.attrPos);
      gl.vertexAttribPointer(this.attrPos, 4, gl.FLOAT, false, 0, 0);
    }

    if (this.attrNor != -1 && d.bindNor()) {
      gl.enableVertexAttribArray(this.attrNor);
      gl.vertexAttribPointer(this.attrNor, 4, gl.FLOAT, false, 0, 0);
    }

    d.bindIdx();
    gl.drawElements(d.drawMode(), d.elemCount(), gl.UNSIGNED_INT, 0);

    if (this.attrPos != -1) gl.disableVertexAttribArray(this.attrPos);
    if (this.attrNor != -1) gl.disableVertexAttribArray(this.attrNor);
  }
};

export default ShaderProgram;
