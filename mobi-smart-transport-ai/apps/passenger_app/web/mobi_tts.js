// Each utterance owns its callbacks. No flutter_tts private state or fixed delay.
(() => {
  let current = null;
  function synth() {
    if (!window.speechSynthesis || !window.SpeechSynthesisUtterance)
      throw new Error('Speech synthesis is unavailable');
    return window.speechSynthesis;
  }
  function settle(run, natural, error) {
    if (run.settled) return;
    run.settled = true;
    if (current === run) current = null;
    if (error) run.reject(error); else run.resolve(natural);
  }
  function stop() {
    const s = synth(), run = current;
    // Retire before cancel: synchronous or delayed old callbacks are harmless.
    current = null;
    if (run) settle(run, false);
    s.cancel();
    // This checks browser output state, not an arbitrary plugin state delay.
    if (!s.speaking && !s.pending) return Promise.resolve(true);
    return new Promise(resolve => {
      const deadline = Date.now() + 1500;
      function check() {
        if (!s.speaking && !s.pending) return resolve(true);
        if (Date.now() >= deadline) return resolve(false);
        window.setTimeout(check, 20);
      }
      check();
    });
  }
  function prepare(korean) {
    const s = synth();
    if (korean && !s.getVoices().some(v => v.lang.toLowerCase().startsWith('ko')))
      throw new Error('Korean voice unavailable');
  }
  function speak(text) {
    const s = synth();
    // The coordinator serializes control commands. Refuse external overlap.
    if (current || s.speaking || s.pending)
      return Promise.reject(new Error('Speech output is busy'));
    return new Promise((resolve, reject) => {
      const utterance = new window.SpeechSynthesisUtterance(text);
      const run = {utterance, resolve, reject, settled:false};
      current = run;
      utterance.lang = 'ko-KR'; utterance.rate = 0.5; utterance.pitch = 1;
      const voice = s.getVoices().find(v => v.lang.toLowerCase().startsWith('ko'));
      if (voice) utterance.voice = voice;
      utterance.onend = () => settle(run, true);
      utterance.onerror = event => {
        const cancelled = event.error === 'canceled' || event.error === 'interrupted';
        settle(run, false, cancelled ? null : new Error('Speech engine failed'));
      };
      try { s.speak(utterance); } catch (error) { settle(run, false, error); }
    });
  }
  window.MobiTts = {prepare, speak, stop};
})();
