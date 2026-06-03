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

  function _openSocket() {
    if (socket && (socket.readyState === 0 || socket.readyState === 1)) return;
    socket = new WebSocket(lastUrl);
    socket.onmessage = (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      if (msg.type === "transcript" && handlers.onTranscript) {
        handlers.onTranscript(msg.text || "", !!msg.isFinal);
      } else if (msg.type === "ready" && handlers.onState) {
        handlers.onState("ready");
      } else if (msg.type === "error" && handlers.onState) {
        handlers.onState("error");
      }
    };
    socket.onclose = () => { if (handlers.onState) handlers.onState("closed"); };
    socket.onerror = () => { if (handlers.onState) handlers.onState("error"); };
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
      if (paused || !socket || socket.readyState !== 1) return;
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
      if (!stream) {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
        });
      }
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!ctx) ctx = new AudioContext();
      if (ctx.state === "suspended") await ctx.resume();
      _attachProcessor();
      _openSocket();
      paused = false;
      running = true;
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
      if (ctx.state === "suspended") await ctx.resume();
      _attachProcessor();
      _openSocket();
      // 이전 턴 잔여 전사가 다음 턴에 섞이지 않도록 서버 버퍼 리셋.
      if (socket && socket.readyState === 1) {
        try { socket.send(JSON.stringify({ type: "reset" })); } catch (_) {}
      }
      running = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  function setPaused(p) { paused = !!p; }
  function getLevel() { return level; } // 전송 멈춰도 RMS는 유지(barge-in용)
  function isRunning() { return running; }

  async function stop() {
    running = false;
    paused = false;
    level = 0.0;
    try { if (socket && socket.readyState === 1) socket.send(JSON.stringify({ type: "stop" })); } catch (_) {}
    try { if (processor) processor.disconnect(); } catch (_) {}
    try { if (source) source.disconnect(); } catch (_) {}
    try { if (socket) socket.close(); } catch (_) {}
    try { if (stream) stream.getTracks().forEach((t) => t.stop()); } catch (_) {}
    try { if (ctx) await ctx.close(); } catch (_) {}
    processor = null; source = null; socket = null; stream = null; ctx = null;
  }

  window.MobiSttMic = {
    setHandlers, start, resume, stop, setPaused, getLevel, isRunning,
    supported: () => !!(navigator.mediaDevices && (window.AudioContext || window.webkitAudioContext) && window.WebSocket),
  };
})();
