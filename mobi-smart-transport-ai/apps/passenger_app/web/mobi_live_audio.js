(() => {
  let audioContext = null;
  let nextStartTime = 0;
  let sampleRate = 24000;
  const activeSources = new Set();
  let analyser = null;
  let analyserBuffer = null;

  function ensureContext() {
    if (!audioContext) {
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) {
        throw new Error("Web Audio API is unavailable.");
      }
      audioContext = new AudioContext();
    }
    if (audioContext.state === "suspended") {
      void audioContext.resume();
    }
    return audioContext;
  }

  function ensureAnalyser(context) {
    if (!analyser) {
      analyser = context.createAnalyser();
      analyser.fftSize = 512;
      analyser.smoothingTimeConstant = 0.6;
      analyser.connect(context.destination);
      analyserBuffer = new Float32Array(analyser.fftSize);
    }
    return analyser;
  }

  function stop() {
    for (const source of activeSources) {
      try {
        source.stop();
      } catch (_) {
        // The source may already have completed naturally.
      }
    }
    activeSources.clear();
    nextStartTime = 0;
  }

  function start(rate) {
    stop();
    sampleRate = Number(rate) || 24000;
    const context = ensureContext();
    ensureAnalyser(context);
    nextStartTime = context.currentTime + 0.04;
  }

  function feedPcmBase64(base64Pcm) {
    const context = ensureContext();
    const node = ensureAnalyser(context);
    const decoded = window.atob(base64Pcm);
    const sampleCount = Math.floor(decoded.length / 2);
    if (!sampleCount) return;

    const samples = new Float32Array(sampleCount);
    for (let index = 0; index < sampleCount; index += 1) {
      const low = decoded.charCodeAt(index * 2);
      const high = decoded.charCodeAt(index * 2 + 1);
      const value = (high << 8) | low;
      const signed = value >= 0x8000 ? value - 0x10000 : value;
      samples[index] = signed / 0x8000;
    }

    const buffer = context.createBuffer(1, sampleCount, sampleRate);
    buffer.copyToChannel(samples, 0);

    const source = context.createBufferSource();
    source.buffer = buffer;
    // 재생 경로에 analyser를 끼워 출력 진폭(주황 오로라)을 측정한다.
    source.connect(node);
    source.addEventListener("ended", () => activeSources.delete(source));
    activeSources.add(source);

    const startAt = Math.max(nextStartTime, context.currentTime + 0.02);
    source.start(startAt);
    nextStartTime = startAt + buffer.duration;
  }

  // 스케줄된(버퍼된) 재생이 끝날 때까지 남은 시간(ms). 통화 종료/전환 시
  // AI 마지막 말이 잘리지 않도록 drain 대기에 사용한다.
  function getRemainingMs() {
    if (!audioContext) return 0;
    const remaining = (nextStartTime - audioContext.currentTime) * 1000;
    return remaining > 0 ? remaining : 0;
  }

  // 현재 AI 출력 오디오의 RMS(0~1). 재생 중이 아니면 0.
  function getOutputLevel() {
    if (!analyser || !analyserBuffer) return 0;
    analyser.getFloatTimeDomainData(analyserBuffer);
    let sum = 0;
    for (let i = 0; i < analyserBuffer.length; i += 1) {
      const v = analyserBuffer[i];
      sum += v * v;
    }
    const rms = Math.sqrt(sum / analyserBuffer.length);
    return Math.min(1, rms * 4.0);
  }

  window.MobiLiveAudio = {
    prepare: ensureContext,
    start,
    feedPcmBase64,
    finish() {},
    stop,
    getOutputLevel,
  };
})();
