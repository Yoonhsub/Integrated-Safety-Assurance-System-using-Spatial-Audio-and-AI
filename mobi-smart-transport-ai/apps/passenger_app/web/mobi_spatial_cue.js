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
    if (ctx.state !== 'running') {
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
    ensureContext();
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
    ensureContext();
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
  var _kicked = false;
  function unlock() {
    var c = ensureContext();
    if (!c) return;
    if (c.state === 'suspended') {
      c.resume().catch(function () {});
    }
    // iOS WebKit(Chrome iOS 포함): 제스처 안에서 무음 버퍼를 한 번 재생해야
    // Web Audio 출력이 실제로 깨어난다.
    if (!_kicked) {
      try {
        var buffer = c.createBuffer(1, 1, 22050);
        var source = c.createBufferSource();
        source.buffer = buffer;
        source.connect(c.destination);
        source.start(0);
        _kicked = true;
      } catch (e) {}
    }
  }
  // Flutter 웹이 포인터 이벤트를 가로채(전파 중단) window 리스너가 안 불릴 수 있으므로,
  // document의 'capture' 단계(타깃 도달 전)에 등록해 어떤 탭이든 반드시 unlock이 먼저 실행되게 한다.
  ['pointerdown', 'touchstart', 'touchend', 'mousedown', 'click', 'keydown'].forEach(function (ev) {
    document.addEventListener(ev, unlock, { capture: true, passive: true });
  });

  // ===== 음성 클립 재생 (beep와 동일한 AudioContext 공유) =====
  // iOS는 동시에 열린 별도 AudioContext 중 하나를 중단시킨다. 그래서 음성(mp3)을
  // audioplayers의 별도 컨텍스트가 아니라 beep와 같은 이 컨텍스트에서 재생해 충돌을 없앤다.
  var voiceGain = null;
  var voiceSource = null;
  var clipCache = {};

  function ensureVoiceGain() {
    var c = ensureContext();
    if (!c) return null;
    if (!voiceGain) {
      voiceGain = c.createGain();
      voiceGain.gain.value = 1.0;
      voiceGain.connect(c.destination);
    }
    return voiceGain;
  }

  function stopClip() {
    if (voiceSource) {
      try { voiceSource.onended = null; voiceSource.stop(); } catch (e) {}
      voiceSource = null;
    }
  }

  function playClip(url) {
    return new Promise(function (resolve) {
      var c = ensureContext();
      var g = ensureVoiceGain();
      if (!c || !g) { resolve(false); return; }
      stopClip();
      function startBuffer(buf) {
        if (!buf) { resolve(false); return; }
        try {
          var src = c.createBufferSource();
          src.buffer = buf;
          src.connect(g);
          voiceSource = src;
          src.onended = function () { if (voiceSource === src) voiceSource = null; resolve(true); };
          src.start(0);
        } catch (e) { resolve(false); }
      }
      if (clipCache[url]) { startBuffer(clipCache[url]); return; }
      fetch(url).then(function (r) { return r.arrayBuffer(); }).then(function (ab) {
        c.decodeAudioData(ab, function (buf) { clipCache[url] = buf; startBuffer(buf); }, function () { resolve(false); });
      }).catch(function () { resolve(false); });
    });
  }

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
    },
    playClip: playClip,
    stopClip: stopClip
  };
})();
