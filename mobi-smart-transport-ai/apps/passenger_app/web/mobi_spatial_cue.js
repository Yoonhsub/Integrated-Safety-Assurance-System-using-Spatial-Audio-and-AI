(function () {
  'use strict';

  var ctx = null;
  var masterGain = null;
  var panner = null;
  var timer = null;
  var step = 0;
  var active = {
    pan: 0,
    gain: 0.45,
    intervalMs: 1200,
    pattern: 'normal'
  };
  var head = {
    enabled: false,
    yaw: 0,
    pitch: 0,
    roll: 0,
    effectivePan: 0
  };

  function clamp(value, min, max) {
    var n = Number(value);
    if (!Number.isFinite(n)) return min;
    return Math.min(max, Math.max(min, n));
  }

  function ensureContext() {
    var AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) return null;
    if (!ctx) {
      ctx = new AudioContext();
      masterGain = ctx.createGain();
      masterGain.gain.value = active.gain;

      if (typeof ctx.createStereoPanner === 'function') {
        panner = ctx.createStereoPanner();
        panner.pan.value = correctedPan();
        head.effectivePan = panner.pan.value;
        masterGain.connect(panner);
        panner.connect(ctx.destination);
      } else {
        panner = null;
        masterGain.connect(ctx.destination);
      }
    }
    if (ctx.state === 'suspended') {
      ctx.resume().catch(function () {});
    }
    return ctx;
  }

  function normalize180(value) {
    var out = Number(value);
    if (!Number.isFinite(out)) return 0;
    out = ((out + 180) % 360 + 360) % 360 - 180;
    return out === -180 ? 180 : out;
  }

  function correctedPan() {
    if (!head.enabled) return active.pan;
    var baseAzimuth = active.pan * 90;
    var relativeAzimuth = normalize180(baseAzimuth - head.yaw);
    return clamp(Math.sin(relativeAzimuth * Math.PI / 180), -1, 1);
  }

  function applyPan() {
    head.effectivePan = correctedPan();
    if (panner && panner.pan) {
      panner.pan.setTargetAtTime(head.effectivePan, ctx.currentTime, 0.015);
    }
  }

  function applyState(options) {
    options = options || {};
    if (options.pan !== undefined) active.pan = clamp(options.pan, -1, 1);
    if (options.gain !== undefined) active.gain = clamp(options.gain, 0, 1);
    if (options.intervalMs !== undefined) {
      active.intervalMs = Math.round(clamp(options.intervalMs, 250, 5000));
    }
    if (options.pattern !== undefined && String(options.pattern).trim()) {
      active.pattern = String(options.pattern);
    }

    if (masterGain) {
      masterGain.gain.setTargetAtTime(active.gain, ctx.currentTime, 0.015);
    }
    if (panner && panner.pan) applyPan();
  }

  function tonePlan(pattern) {
    switch (pattern) {
      case 'alarm':
        return [
          { frequency: 880, durationMs: 110, delayMs: 0, type: 'square' },
          { frequency: 660, durationMs: 110, delayMs: 160, type: 'square' }
        ];
      case 'warning':
        return [
          { frequency: step % 2 === 0 ? 740 : 980, durationMs: 130, delayMs: 0, type: 'triangle' }
        ];
      case 'missed':
        return [
          { frequency: 330, durationMs: 260, delayMs: 0, type: 'sine' }
        ];
      default:
        return [
          { frequency: 880, durationMs: 95, delayMs: 0, type: 'sine' }
        ];
    }
  }

  function playTone(tone) {
    var audio = ensureContext();
    if (!audio || !masterGain) return;

    var oscillator = audio.createOscillator();
    var envelope = audio.createGain();
    var startAt = audio.currentTime + (tone.delayMs || 0) / 1000;
    var endAt = startAt + (tone.durationMs || 100) / 1000;

    oscillator.type = tone.type || 'sine';
    oscillator.frequency.setValueAtTime(tone.frequency || 880, startAt);
    envelope.gain.setValueAtTime(0.0001, startAt);
    envelope.gain.exponentialRampToValueAtTime(Math.max(0.0001, active.gain), startAt + 0.015);
    envelope.gain.exponentialRampToValueAtTime(0.0001, endAt);

    oscillator.connect(envelope);
    envelope.connect(masterGain);
    oscillator.start(startAt);
    oscillator.stop(endAt + 0.02);
  }

  function beep() {
    tonePlan(active.pattern).forEach(playTone);
    step += 1;
  }

  function restartTimer() {
    if (timer) window.clearInterval(timer);
    timer = window.setInterval(beep, active.intervalMs);
  }

  function prepare() {
    ensureContext();
  }

  function start(options) {
    prepare();
    applyState(options);
    stop(false);
    beep();
    restartTimer();
  }

  function update(options) {
    var previousInterval = active.intervalMs;
    applyState(options);
    if (timer && previousInterval !== active.intervalMs) {
      restartTimer();
    }
  }

  function stop(resetStep) {
    if (timer) {
      window.clearInterval(timer);
      timer = null;
    }
    if (resetStep !== false) step = 0;
  }

  function alarm(pattern) {
    start({
      pan: 0,
      gain: 0.9,
      intervalMs: pattern === 'missed' ? 900 : 420,
      pattern: pattern || 'alarm'
    });
  }

  function setHeadOrientation(yaw, pitch, roll, enabled) {
    head.enabled = enabled === true;
    head.yaw = normalize180(yaw || 0);
    head.pitch = Number.isFinite(Number(pitch)) ? Number(pitch) : 0;
    head.roll = Number.isFinite(Number(roll)) ? Number(roll) : 0;
    if (panner && panner.pan) applyPan();
  }

  function getState() {
    return {
      pan: active.pan,
      effectivePan: head.effectivePan,
      gain: active.gain,
      intervalMs: active.intervalMs,
      pattern: active.pattern,
      headTrackingEnabled: head.enabled,
      headYaw: head.yaw,
      headPitch: head.pitch,
      headRoll: head.roll
    };
  }

  window.MobiSpatialCue = {
    prepare: prepare,
    start: start,
    update: update,
    stop: stop,
    alarm: alarm,
    setHeadOrientation: setHeadOrientation,
    getState: getState,
    startCue: function (pan, gain, intervalMs, pattern) {
      start({ pan: pan, gain: gain, intervalMs: intervalMs, pattern: pattern });
    },
    updateCue: function (pan, gain, intervalMs, pattern) {
      update({ pan: pan, gain: gain, intervalMs: intervalMs, pattern: pattern });
    }
  };
})();
