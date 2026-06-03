// 서버 STT용 마이크 캡처: getUserMedia로 마이크를 열어 16kHz PCM16으로 변환,
// /agent/stt/live WebSocket으로 스트리밍하고 전사 결과를 콜백으로 돌려준다.
// 브라우저 Web Speech API의 무제스처 재시작 제약을 우회한다.
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
      let s = Math.max(-1, Math.min(1, floats[i]));
      view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    let binary = "";
    const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return window.btoa(binary);
  }

  async function start(wsUrl, lang) {
    if (running) return true;
    if (!navigator.mediaDevices) return false;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          channelCount: 1,
        },
      });
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      ctx = new AudioContext();
      if (ctx.state === "suspended") await ctx.resume();
      source = ctx.createMediaStreamSource(stream);
      processor = ctx.createScriptProcessor(4096, 1, 1);
      source.connect(processor);
      processor.connect(ctx.destination); // 일부 브라우저는 연결돼야 onaudioprocess 발화
      socket = new WebSocket(wsUrl);
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

      processor.onaudioprocess = (e) => {
        const input = e.inputBuffer.getChannelData(0);
        // RMS(오로라용)
        let sum = 0;
        for (let i = 0; i < input.length; i += 1) sum += input[i] * input[i];
        const rms = Math.sqrt(sum / input.length);
        level = Math.min(1, rms * 4.0);
        if (paused || !socket || socket.readyState !== 1) return;
        const ds = _downsampleTo16k(input, ctx.sampleRate);
        const b64 = _floatToPcm16Base64(ds);
        try {
          socket.send(JSON.stringify({ type: "audio", data: b64, sampleRate: 16000 }));
        } catch (_) {}
      };
      running = true;
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  function setPaused(p) { paused = !!p; }
  // 전송만 멈추고 RMS는 계속 계산한다(AI 발화 중 barge-in 감지를 위해).
  function getLevel() { return level; }
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
    setHandlers, start, stop, setPaused, getLevel, isRunning,
    supported: () => !!(navigator.mediaDevices && (window.AudioContext || window.webkitAudioContext) && window.WebSocket),
  };
})();
