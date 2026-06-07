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
        panner.pan.value = active.pan;
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
    if (panner && panner.pan) {
      panner.pan.setTargetAtTime(active.pan, ctx.currentTime, 0.015);
    }
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

  // iOS/Safari 등은 AudioContext가 사용자 제스처 안에서만 resume된다.
  // 타이머에서 호출되는 start/update의 resume()은 차단되므로, 첫 사용자 제스처
  // (예: 시나리오 재생 탭)에 컨텍스트를 생성·resume해 beep가 들리도록 잠금 해제한다.
  function unlock() {
    var c = ensureContext();
    if (c && c.state === 'suspended') {
      c.resume().catch(function () {});
    }
  }
  ['pointerdown', 'touchend', 'mousedown', 'keydown'].forEach(function (ev) {
    window.addEventListener(ev, unlock, { passive: true });
  });

  window.MobiSpatialCue = {
    prepare: prepare,
    start: start,
    update: update,
    stop: stop,
    alarm: alarm,
    startCue: function (pan, gain, intervalMs, pattern) {
      start({ pan: pan, gain: gain, intervalMs: intervalMs, pattern: pattern });
    },
    updateCue: function (pan, gain, intervalMs, pattern) {
      update({ pan: pan, gain: gain, intervalMs: intervalMs, pattern: pattern });
    }
  };
})();
