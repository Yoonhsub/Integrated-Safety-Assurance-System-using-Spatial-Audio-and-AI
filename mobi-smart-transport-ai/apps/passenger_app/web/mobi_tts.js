// Each utterance owns its callbacks. No flutter_tts private state or fixed delay.
(() => {
  let current = null, sequence = 0, phase = 'idle', outcome = null, selectedVoice = null;
  const counts = {starts:0, completions:0, cancellations:0, stops:0, errors:0};
  const events = [];
  function mark(kind, run) {
    events.push({kind, runId:run ? run.id : sequence, at:Date.now()});
    if (events.length > 32) events.shift();
  }
  function koreanVoice(s) {
    const voices = s.getVoices();
    return voices.find(v => v.localService === true && v.lang.toLowerCase().startsWith('ko')) ||
      voices.find(v => v.lang.toLowerCase().startsWith('ko'));
  }
  function synth() {
    if (!window.speechSynthesis || !window.SpeechSynthesisUtterance)
      throw new Error('Speech synthesis is unavailable');
    return window.speechSynthesis;
  }
  function settle(run, natural, error) {
    if (run.settled) return;
    run.settled = true;
    const active = current === run;
    if (active) current = null;
    outcome = error ? 'failed' : natural ? 'completed' : 'cancelled';
    if (error) counts.errors++; else if (natural) counts.completions++; else counts.cancellations++;
    if (active) phase = outcome;
    mark(outcome, run);
    if (error) run.reject(error); else run.resolve(natural);
  }
  function stop() {
    const s = synth(), run = current;
    phase = 'stopping'; counts.stops++; mark('stop_requested', run);
    // Retire before cancel: synchronous or delayed old callbacks are harmless.
    current = null;
    if (run) settle(run, false);
    s.cancel();
    // This checks browser output state, not an arbitrary plugin state delay.
    if (!s.speaking && !s.pending) { phase = 'stopped'; mark('stop_confirmed', run); return Promise.resolve(true); }
    return new Promise(resolve => {
      const deadline = Date.now() + 1500;
      function check() {
        if (!s.speaking && !s.pending) { phase = 'stopped'; mark('stop_confirmed', run); return resolve(true); }
        if (Date.now() >= deadline) { phase = 'stop_unconfirmed'; mark('stop_unconfirmed', run); return resolve(false); }
        window.setTimeout(check, 20);
      }
      check();
    });
  }
  function prepare(korean) {
    const s = synth();
    selectedVoice = koreanVoice(s) || null;
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
      const run = {id:++sequence, utterance, resolve, reject, settled:false};
      current = run; phase = 'requested'; mark('speak_requested', run);
      utterance.lang = 'ko-KR'; utterance.rate = 0.5; utterance.pitch = 1;
      const voice = koreanVoice(s);
      selectedVoice = voice || null;
      if (voice) utterance.voice = voice;
      utterance.onstart = () => { if (current === run && !run.settled) { phase = 'speaking'; counts.starts++; mark('started', run); } };
      utterance.onend = () => settle(run, true);
      utterance.onerror = event => {
        const cancelled = event.error === 'canceled' || event.error === 'interrupted';
        settle(run, false, cancelled ? null : new Error('Speech engine failed'));
      };
      try { s.speak(utterance); } catch (error) { settle(run, false, error); }
    });
  }
  function snapshot() {
    try {
      const s = synth();
      return JSON.stringify({supported:true,phase,outcome,runId:sequence,
        nativeSpeaking:s.speaking,nativePending:s.pending,
        localKoreanAvailable:s.getVoices().some(v => v.localService === true && v.lang.toLowerCase().startsWith('ko')),
        selectedVoiceLocal:selectedVoice ? selectedVoice.localService === true : null,
        selectedVoiceLang:selectedVoice ? selectedVoice.lang : null,counts:{...counts},events:[...events]});
    } catch (_) { return JSON.stringify({supported:false,phase:'unavailable'}); }
  }
  window.MobiTts = {prepare, speak, stop, snapshot};
})();
