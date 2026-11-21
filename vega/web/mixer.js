// Inputs are decoded canvases owned by the app. Vega's system video surface is opaque.
export function createMixer(width, height) {
  let canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const gl = canvas.getContext("webgl2", {
    alpha: false,
    antialias: false,
    depth: false,
  });
  if (gl) {
    try {
      const program = gl.createProgram();
      for (const [kind, source] of [
        [
          gl.VERTEX_SHADER,
          `#version 300 es
        out vec2 uv;
        void main() {
          vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
          uv = vec2(p.x, 1.0-p.y);
          gl_Position = vec4(p*2.0-1.0, 0.0, 1.0);
        }`,
        ],
        [
          gl.FRAGMENT_SHADER,
          `#version 300 es
        precision mediump float;
        uniform sampler2D earlier, later;
        uniform float phase;
        in vec2 uv;
        out vec4 pixel;
        void main() {pixel = mix(texture(earlier, uv),texture(later, uv),phase);}`,
        ],
      ]) {
        const shader = gl.createShader(kind);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS))
          throw Error("Shader unavailable");
        gl.attachShader(program, shader);
        gl.deleteShader(shader);
      }
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS))
        throw Error("Frame mixer unavailable");
      gl.useProgram(program);
      const phase = gl.getUniformLocation(program, "phase");
      const textures = [0, 1].map((i) => {
        gl.activeTexture(gl.TEXTURE0 + i);
        const texture = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.uniform1i(
          gl.getUniformLocation(program, i ? "later" : "earlier"),
          i
        );
        return texture;
      });
      const uploaded = [null, null];
      return {
        canvas,
        provider: "WebGL 2",
        draw(a, b, t) {
          for (const [i, frame] of [a, b].entries()) {
            if (uploaded[i] === frame) continue;
            gl.activeTexture(gl.TEXTURE0 + i);
            gl.bindTexture(gl.TEXTURE_2D, textures[i]);
            gl.texImage2D(
              gl.TEXTURE_2D,
              0,
              gl.RGBA,
              gl.RGBA,
              gl.UNSIGNED_BYTE,
              frame.canvas
            );
            uploaded[i] = frame;
          }
          gl.uniform1f(phase, t);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
          if (gl.isContextLost() || gl.getError() !== gl.NO_ERROR)
            throw Error("Frame upload failed");
        },
        close() {
          gl.getExtension("WEBGL_lose_context")?.loseContext();
        },
      };
    } catch {
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    }
  }
  return createCpuMixer(width, height);
}

export function createCpuMixer(width, height) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d", {
    alpha: false,
    willReadFrequently: true,
  });
  const output = ctx.createImageData(width, height);
  const cache = new WeakMap();
  function pixels(frame) {
    if (!cache.has(frame)) {
      const image = frame.canvas
        .getContext("2d")
        .getImageData(0, 0, width, height);
      cache.set(frame, image.data);
    }
    return cache.get(frame);
  }
  return {
    canvas,
    provider: "CPU",
    draw(a, b, t) {
      const left = pixels(a),
        right = pixels(b);
      for (let i = 0; i < output.data.length; i++)
        output.data[i] = left[i] + (right[i] - left[i]) * t;
      ctx.putImageData(output, 0, 0);
    },
    close() {},
  };
}
