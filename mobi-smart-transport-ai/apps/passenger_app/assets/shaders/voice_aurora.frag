#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;

// Uniform 매핑(Dart에서 index 순서대로 setFloat).
uniform float uWidth;   // 0
uniform float uHeight;  // 1
uniform float uTime;    // 2
uniform float uLevel;   // 3  0.0~1.0 실제 오디오 RMS(또는 thinking pulse)
uniform float uMode;    // 4  0 idle / 1 listening / 2 thinking / 3 speaking

out vec4 fragColor;

// 값 잡음(value noise) 기반 부드러운 fbm. octave를 적게 써서 저사양에서도 가볍게.
float hash(vec2 p) {
  p = fract(p * vec2(123.34, 345.45));
  p += dot(p, p + 34.345);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 4; i++) {
    v += amp * noise(p);
    p *= 1.9;
    amp *= 0.5;
  }
  return v;
}

// 모드별 옅음/짙음이 공존하는 그라데이션 팔레트.
// 진한 단색이 아니라 두세 톤을 섞어 우아한 느낌을 낸다.
void palette(float mode, out vec3 deep, out vec3 mid, out vec3 light) {
  if (mode < 0.5) {
    // idle: 아주 옅은 청회색 glow
    deep = vec3(0.04, 0.06, 0.10);
    mid = vec3(0.10, 0.16, 0.26);
    light = vec3(0.22, 0.34, 0.48);
  } else if (mode < 1.5) {
    // listening: blue ~ cyan 그라데이션
    deep = vec3(0.02, 0.10, 0.28);
    mid = vec3(0.06, 0.42, 0.78);
    light = vec3(0.45, 0.85, 0.98);
  } else if (mode < 2.5) {
    // thinking: blue ~ violet 그라데이션
    deep = vec3(0.10, 0.06, 0.30);
    mid = vec3(0.35, 0.22, 0.72);
    light = vec3(0.62, 0.55, 0.96);
  } else {
    // speaking: amber ~ gold 그라데이션
    deep = vec3(0.30, 0.10, 0.02);
    mid = vec3(0.92, 0.45, 0.10);
    light = vec3(1.00, 0.82, 0.42);
  }
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 res = vec2(uWidth, uHeight);
  vec2 uv = fragCoord / res;

  // y: 0 = 위, 1 = 아래. 오로라는 아래에서 위로 퍼진다.
  float fromBottom = 1.0 - uv.y;

  float level = clamp(uLevel, 0.0, 1.0);
  // 진폭에 따라 오로라가 위로 더 올라오고 더 밝아진다.
  float rise = mix(0.30, 0.78, level);

  // 흐르는 노이즈 결(조금 더 빠르게 흘러 또렷하게 울렁이도록).
  float t = uTime;
  float flow =
      fbm(vec2(uv.x * 3.0 + t * 0.16, fromBottom * 2.2 - t * 0.26));
  float flow2 =
      fbm(vec2(uv.x * 6.0 - t * 0.12, fromBottom * 3.0 + t * 0.19));
  float wave = mix(flow, flow2, 0.5);

  // 진폭이 클수록 결이 들쭉날쭉하게 출렁인다.
  float jitter = (wave - 0.5) * mix(0.18, 0.62, level);
  // 좌우로 부드럽게 굽이치는 큰 파동을 더해 통화 중 생동감을 준다.
  float swell = sin(uv.x * 6.2831 + t * 0.9) * 0.05 * (0.4 + level);
  float band = rise + jitter + swell;

  // 아래쪽일수록 진하고 위로 갈수록 부드럽게 사라지는 세로 마스크.
  float vertical = smoothstep(band + 0.30, 0.0, fromBottom);
  vertical = pow(vertical, 1.4);

  // 가로로 살짝 뭉치는 빛 덩어리(균일한 단색 방지).
  float clump = 0.65 + 0.35 * fbm(vec2(uv.x * 2.0 - t * 0.05, t * 0.08));

  float intensity = vertical * clump;
  intensity *= mix(0.6, 1.45, level);

  vec3 deep, mid, light;
  palette(uMode, deep, mid, light);

  // 높이와 노이즈로 deep↔mid↔light를 섞어 옅음/짙음 공존 그라데이션을 만든다.
  float g = clamp(fromBottom / max(band + 0.30, 0.001), 0.0, 1.0);
  vec3 grad = mix(light, mid, smoothstep(0.0, 0.55, g));
  grad = mix(grad, deep, smoothstep(0.45, 1.0, g));
  // 노이즈로 톤을 한 번 더 흔들어 균일감을 줄인다.
  grad = mix(grad, light, (wave - 0.5) * 0.25 * level);

  float alpha = clamp(intensity, 0.0, 1.0);
  // 위쪽 끝은 완전히 투명하게.
  alpha *= smoothstep(0.0, 0.12, fromBottom);

  // speaking(주황) 모드는 하단부가 너무 진하지 않게 살짝 약하게 한다.
  if (uMode > 2.5) {
    alpha *= 0.8;
  }

  vec3 color = grad * (0.9 + 0.7 * level);
  // premultiplied alpha 출력.
  fragColor = vec4(color * alpha, alpha);
}
