// 서버 STT용 마이크 캡처: getUserMedia로 마이크를 열어 16kHz PCM16으로 변환,
// /agent/stt/live WebSocket으로 스트리밍하고 전사 결과를 콜백으로 돌려준다.
// 브라우저 Web Speech API의 무제스처 재시작 제약을 우회한다.
// iOS는 TTS 재생 후 마이크 AudioContext가 suspend되거나 WS가 닫힐 수 있어,
// resume()으로 컨텍스트 재개 + WS 재연결 + 버퍼 리셋을 수행한다.
(() => {
  let ctx = null;
  let stream = null;
  let source = null;
  let processor = null;
  let socket = null;
  let handlers = {};
  let paused = false;
  let level = 0.0;
  let running = false;
  let lastUrl = "";
  let watchdog = null;
  let recoveryTimer = null;

  function setHandlers(onTranscript, onState) {
    handlers = { onTranscript, onState };
  }

  function _downsampleTo16k(input, inRate) {
    if (inRate === 16000) return input;
    const ratio = inRate / 16000;
    const outLen = Math.floor(input.length / ratio);
    const out = new Float32Array(outLen);
    for (let i = 0; i < outLen; i += 1) {
      const pos = i * ratio;
      const j = Math.floor(pos);
      const frac = pos - j;
      const s0 = input[j] || 0;
      const s1 = input[j + 1] !== undefined ? input[j + 1] : s0;
      out[i] = s0 + (s1 - s0) * frac;
    }
    return out;
  }

  function _floatToPcm16Base64(floats) {
    const buf = new ArrayBuffer(floats.length * 2);
    const view = new DataView(buf);
    for (let i = 0; i < floats.length; i += 1) {
      const s = Math.max(-1, Math.min(1, floats[i]));
      view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    let binary = "";
    const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return window.btoa(binary);
  }

  function _emitState(state) {
    if (handlers.onState) handlers.onState(state);
  }

  function _scheduleRecover(delayMs = 350) {
    if (!running || recoveryTimer) return;
    recoveryTimer = window.setTimeout(async () => {
      recoveryTimer = null;
      await resume();
    }, delayMs);
  }

  function _openSocket() {
    if (!lastUrl) return;
    if (socket && (socket.readyState === 0 || socket.readyState === 1)) return;
    try {
      socket = new WebSocket(lastUrl);
    } catch (_) {
      _scheduleRecover(1000);
      return;
    }
    socket.onopen = () => _emitState("listening");
    socket.onmessage = (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      if (msg.type === "transcript" && handlers.onTranscript) {
        handlers.onTranscript(msg.text || "", !!msg.isFinal);
      } else if (msg.type === "ready") {
        _emitState("ready");
      } else if (msg.type === "error") {
        _emitState("error");
      }
    };
    socket.onclose = () => {
      _emitState("closed");
      _scheduleRecover();
    };
    socket.onerror = () => {
      _emitState("error");
      _scheduleRecover(700);
    };
  }

  function _startWatchdog() {
    if (watchdog) return;
    watchdog = window.setInterval(() => {
      if (!running) return;
      const suspended = ctx && ctx.state === "suspended";
      const socketClosed = !socket || socket.readyState === 2 || socket.readyState === 3;
      if (suspended || socketClosed) _scheduleRecover(0);
    }, 1000);
  }

  function _stopWatchdog() {
    if (watchdog) window.clearInterval(watchdog);
    if (recoveryTimer) window.clearTimeout(recoveryTimer);
    watchdog = null;
    recoveryTimer = null;
  }

  async function _resumeContext() {
    if (!ctx) return false;
    if (ctx.state === "suspended") {
      try { await ctx.resume(); } catch (_) {}
    }
    if (ctx.state === "suspended") {
      _emitState("resumeBlocked");
      return false;
    }
    return true;
  }

  function _attachProcessor() {
    if (!ctx || !stream) return;
    if (!source) source = ctx.createMediaStreamSource(stream);
    if (processor) return;
    processor = ctx.createScriptProcessor(4096, 1, 1);
    source.connect(processor);
    processor.connect(ctx.destination); // 일부 브라우저는 연결돼야 onaudioprocess 발화
    processor.onaudioprocess = (e) => {
      const input = e.inputBuffer.getChannelData(0);
      let sum = 0;
      for (let i = 0; i < input.length; i += 1) sum += input[i] * input[i];
      level = Math.min(1, Math.sqrt(sum / input.length) * 4.0);
      if (!running) return;
      if (!socket || socket.readyState > 1) {
        _openSocket();
        return;
      }
      if (socket.readyState !== 1) return;
      const ds = _downsampleTo16k(input, ctx.sampleRate);
      try {
        socket.send(JSON.stringify({ type: "audio", data: _floatToPcm16Base64(ds), sampleRate: 16000 }));
      } catch (_) {}
    };
  }

  async function start(wsUrl, lang) {
    lastUrl = wsUrl || lastUrl;
    if (!navigator.mediaDevices) return false;
    try {
      // 세션 동안 살려 둔 마이크 스트림이 있으면 재사용해 권한을 다시 묻지 않는다.
      // 단, iOS가 백그라운드에서 트랙을 끝낸 경우(ended)엔 재획득한다.
      const tracksLive = stream &&
        stream.getTracks().length > 0 &&
        stream.getTracks().every((t) => t.readyState === "live");
      if (!tracksLive) {
        if (stream) { try { stream.getTracks().forEach((t) => t.stop()); } catch (_) {} }
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
        });
      }
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!ctx) ctx = new AudioContext();
      paused = false;
      running = true;
      _startWatchdog();
      if (!(await _resumeContext())) return false;
      _attachProcessor();
      _openSocket();
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  // TTS 재생 후 등으로 멈춘 마이크를 복구: 컨텍스트 재개 + WS 재연결 + 버퍼 리셋.
  async function resume() {
    paused = false;
    try {
      if (!stream || !ctx) return await start(lastUrl);
      if (!(await _resumeContext())) return false;
      _attachProcessor();
      _openSocket();
      // 이전 턴 잔여 전사가 다음 턴에 섞이지 않도록 서버 버퍼 리셋.
      if (socket && socket.readyState === 1) {
        try { socket.send(JSON.stringify({ type: "reset" })); } catch (_) {}
      } else if (socket) {
        socket.addEventListener("open", () => {
          try { socket.send(JSON.stringify({ type: "reset" })); } catch (_) {}
        }, { once: true });
      }
      running = true;
      _startWatchdog();
      return true;
    } catch (_) {
      _emitState("resumeBlocked");
      return false;
    }
  }

  function setPaused(p) {
    // Keep the capture graph and WebSocket alive across AI turns. Dart ignores
    // transcripts while not listening and calls resume(), which resets the
    // server buffer before the next user turn.
    paused = !!p;
    if (running && !paused) {
      resume();
    }
  }
  function getLevel() { return level; } // 전송 멈춰도 RMS는 유지(barge-in용)
  function isRunning() { return running; }
  function needsRecovery() {
    return !!(running && ((!ctx || ctx.state === "suspended") || (!socket || socket.readyState > 1)));
  }

  // 소프트 정지: 전송·분석·소켓만 멈추고 **마이크 스트림(stream)과 오디오
  // 컨텍스트(ctx)는 세션 동안 유지**한다. 이렇게 하면 Live를 다시 열 때
  // getUserMedia를 새로 호출하지 않아 권한을 매번 다시 묻지 않는다.
  // (마이크 표시등은 켜진 채 유지되며, 앱(탭)을 닫으면 자동 해제된다.)
  async function stop() {
    running = false;
    paused = false;
    level = 0.0;
    _stopWatchdog();
    try { if (socket && socket.readyState === 1) socket.send(JSON.stringify({ type: "stop" })); } catch (_) {}
    try { if (processor) processor.disconnect(); } catch (_) {}
    try { if (source) source.disconnect(); } catch (_) {}
    try { if (socket) socket.close(); } catch (_) {}
    processor = null; source = null; socket = null;
    // stream/ctx 는 의도적으로 유지(권한 재요청 방지). 해제는 release().
  }

  // 하드 해제: 마이크 트랙까지 완전히 닫는다(표시등 꺼짐). 앱(탭) 종료 시 호출.
  async function release() {
    await stop();
    try { if (stream) stream.getTracks().forEach((t) => t.stop()); } catch (_) {}
    try { if (ctx) await ctx.close(); } catch (_) {}
    stream = null; ctx = null;
  }

  // 페이지(앱)가 닫히거나 백그라운드로 사라질 때 마이크를 확실히 해제한다.
  try {
    window.addEventListener("pagehide", () => { release(); });
  } catch (_) {}

  window.MobiSttMic = {
    setHandlers, start, resume, stop, release, setPaused, getLevel, isRunning, needsRecovery,
    supported: () => !!(navigator.mediaDevices && (window.AudioContext || window.webkitAudioContext) && window.WebSocket),
  };
})();
