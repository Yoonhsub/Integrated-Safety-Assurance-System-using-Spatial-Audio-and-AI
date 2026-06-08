(function () {
  'use strict';

  var ctx = null;
  var masterGain = null;
  var panner = null;
  var timer = null;
  var step = 0;
  var lastBeepAt = 0;
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

  function nowMs() {
    return window.performance && performance.now
      ? performance.now()
      : Date.now();
  }

  function beep() {
    ensureContext();
    tonePlan(active.pattern).forEach(playTone);
    step += 1;
    lastBeepAt = nowMs();
  }

  // updateCue가 짧은 주기로 자주 호출돼 setInterval(beep, interval)이 매번 리셋되면
  // 다음 beep 전에 타이머가 초기화되어 최초 1회만 울리는 문제가 있었다(#57). 짧은 틱으로
  // 경과 시간만 확인해 interval을 만족할 때만 beep를 울려 반복 재생을 보장한다.
  function tickBeep() {
    if (nowMs() - lastBeepAt >= active.intervalMs) {
      beep();
    }
  }

  function restartTimer() {
    if (timer) window.clearInterval(timer);
    timer = window.setInterval(tickBeep, 40);
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
    applyState(options);
    // restartTimer()를 호출하지 않는다: tickBeep가 interval을 직접 확인하므로
    // updateCue가 반복돼도 타이머를 리셋하지 않아 beep가 끊기지 않는다(#57).
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
  var _silentEl = null;
  var _keeperEl = null;
  var KEEPER_MP3 = 'data:audio/mpeg;base64,SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYxLjcuMTAwAAAAAAAAAAAAAAD/4zjAAAAAAAAAAAAASW5mbwAAAA8AAAAQAAAFWAA1NTU1NTVDQ0NDQ0NQUFBQUFBeXl5eXl5ra2tra2treXl5eXl5hoaGhoaGlJSUlJSUoaGhoaGhoa+vr6+vr7y8vLy8vMrKysrKytfX19fX19fl5eXl5eXy8vLy8vL///////8AAAAATGF2YzYxLjE5AAAAAAAAAAAAAAAAJAKAAAAAAAAABVgIAJWUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/4xjEAAAAA0gAAAAATEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjEOwAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjEdgAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjEsQAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/4xjExAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU=';
  var SILENT_MP3 = 'data:audio/mpeg;base64,SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYxLjcuMTAwAAAAAAAAAAAAAAD/4zjAAAAAAAAAAAAASW5mbwAAAA8AAAADAAABsACqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqrV1dXV1dXV1dXV1dXV1dXV1dXV1dXV1dXV1dXV1dXV1dX///////////////////////////////////////////8AAAAATGF2YzYxLjE5AAAAAAAAAAAAAAAAJALwAAAAAAAAAbD3CmUrAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/4xjEAAAAA0gAAAAATEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/4xjEOwAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/4xjEdgAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU=';
  function unlock() {
    var c = ensureContext();
    if (!c) return;
    if (c.state !== 'running') {
      c.resume().catch(function () {});
    }
    if (!_kicked) {
      // (1) Web Audio 무음 버퍼 kick
      try {
        var buffer = c.createBuffer(1, 1, 22050);
        var source = c.createBufferSource();
        source.buffer = buffer;
        source.connect(c.destination);
        source.start(0);
      } catch (e) {}
      // (2) iOS는 Web Audio만으로는 미디어 세션이 안 깨어나는 경우가 있어,
      // 제스처 안에서 무음 HTMLAudio를 1회 재생해 오디오 출력을 활성화한다.
      try {
        if (!_silentEl) {
          _silentEl = new Audio(SILENT_MP3);
          _silentEl.setAttribute('playsinline', '');
          _silentEl.muted = false;
          _silentEl.volume = 0.01;
        }
        var p = _silentEl.play();
        if (p && p.then) { p.then(function () {}).catch(function () {}); }
      } catch (e) {}
      // (3) iOS는 컨텍스트에 활성 '미디어 엘리먼트 소스'가 있어야 출력이 유지된다
      // (audioplayers가 소리 나는 이유). beep 전용 컨텍스트에 무음 루프를 상시 물려
      // 음성(다른 오디오) 재생 중에도 beep 컨텍스트가 죽지 않게 한다.
      try {
        if (!_keeperEl) {
          _keeperEl = new Audio(KEEPER_MP3);
          _keeperEl.loop = true;
          _keeperEl.volume = 0.0;
          _keeperEl.setAttribute('playsinline', '');
          var ksrc = c.createMediaElementSource(_keeperEl);
          ksrc.connect(c.destination);
          _keeperEl.play().then(function () {}).catch(function () {});
        }
      } catch (e) {}
      _kicked = true;
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
  var voicePanner = null;
  var voiceSource = null;
  var voiceResolve = null;
  var clipCache = {};
  var activeVoice = {
    pan: 0,
    gain: 1
  };

  function ensureVoiceNodes() {
    var c = ensureContext();
    if (!c) return null;
    if (!voiceGain) {
      voiceGain = c.createGain();
      voiceGain.gain.value = 1.0;
      if (typeof c.createStereoPanner === 'function') {
        voicePanner = c.createStereoPanner();
        voicePanner.pan.value = activeVoice.pan;
        voiceGain.connect(voicePanner);
        voicePanner.connect(c.destination);
      } else {
        voicePanner = null;
        voiceGain.connect(c.destination);
      }
    }
    return voiceGain;
  }

  function applyVoiceSpatial(options) {
    options = options || {};
    if (options.pan !== undefined) activeVoice.pan = clamp(options.pan, -1, 1);
    if (options.gain !== undefined) activeVoice.gain = clamp(options.gain, 0, 1.3);
    if (!ctx || !voiceGain) return;
    voiceGain.gain.setTargetAtTime(activeVoice.gain, ctx.currentTime, 0.025);
    if (voicePanner && voicePanner.pan) {
      voicePanner.pan.setTargetAtTime(activeVoice.pan, ctx.currentTime, 0.025);
    }
  }

  function stopClip() {
    if (voiceResolve) {
      var resolve = voiceResolve;
      voiceResolve = null;
      resolve(false);
    }
    if (voiceSource) {
      try { voiceSource.onended = null; voiceSource.stop(); } catch (e) {}
      voiceSource = null;
    }
  }

  function playClip(url, pan, gain) {
    return new Promise(function (resolve) {
      var c = ensureContext();
      var g = ensureVoiceNodes();
      if (!c || !g) { resolve(false); return; }
      stopClip();
      voiceResolve = resolve;
      function finish(ok) {
        if (voiceResolve === resolve) {
          voiceResolve = null;
          resolve(ok);
        }
      }
      applyVoiceSpatial({ pan: pan, gain: gain });
      function startBuffer(buf) {
        if (!buf) { finish(false); return; }
        try {
          var src = c.createBufferSource();
          src.buffer = buf;
          src.connect(g);
          voiceSource = src;
          src.onended = function () {
            if (voiceSource === src) voiceSource = null;
            finish(true);
          };
          src.start(0);
        } catch (e) { finish(false); }
      }
      if (clipCache[url]) { startBuffer(clipCache[url]); return; }
      fetch(url).then(function (r) { return r.arrayBuffer(); }).then(function (ab) {
        c.decodeAudioData(ab, function (buf) { clipCache[url] = buf; startBuffer(buf); }, function () { finish(false); });
      }).catch(function () { finish(false); });
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
    updateClipSpatial: function (pan, gain) {
      ensureContext();
      ensureVoiceNodes();
      applyVoiceSpatial({ pan: pan, gain: gain });
    },
    playClip: playClip,
    stopClip: stopClip
  };
})();
