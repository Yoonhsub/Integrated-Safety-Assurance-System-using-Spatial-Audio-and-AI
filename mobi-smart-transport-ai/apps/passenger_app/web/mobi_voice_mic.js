// 마이크 입력 RMS(0~1)를 Web Audio AnalyserNode로 측정한다.
// 음성 인식(speech_to_text, Web Speech API)과 별개의 getUserMedia 스트림이며,
// 파란 오로라 반응과 무음 감지(VAD) 보조에 쓰인다. 텍스트 인식은 하지 않는다.
(() => {
  let context = null;
  let stream = null;
  let source = null;
  let analyser = null;
  let buffer = null;
  let running = false;

  async function start() {
    if (running) return true;
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext || !navigator.mediaDevices) return false;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      context = new AudioContext();
      if (context.state === "suspended") {
        await context.resume();
      }
      source = context.createMediaStreamSource(stream);
      analyser = context.createAnalyser();
      analyser.fftSize = 512;
      analyser.smoothingTimeConstant = 0.5;
      source.connect(analyser);
      buffer = new Float32Array(analyser.fftSize);
      running = true;
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  function getLevel() {
    if (!running || !analyser || !buffer) return 0;
    analyser.getFloatTimeDomainData(buffer);
    let sum = 0;
    for (let i = 0; i < buffer.length; i += 1) {
      const v = buffer[i];
      sum += v * v;
    }
    const rms = Math.sqrt(sum / buffer.length);
    return Math.min(1, rms * 4.0);
  }

  async function stop() {
    running = false;
    try {
      if (source) source.disconnect();
    } catch (_) {}
    try {
      if (stream) {
        for (const track of stream.getTracks()) track.stop();
      }
    } catch (_) {}
    try {
      if (context) await context.close();
    } catch (_) {}
    source = null;
    analyser = null;
    buffer = null;
    stream = null;
    context = null;
  }

  window.MobiVoiceMic = {
    start,
    getLevel,
    stop,
    isRunning: () => running,
  };
})();
