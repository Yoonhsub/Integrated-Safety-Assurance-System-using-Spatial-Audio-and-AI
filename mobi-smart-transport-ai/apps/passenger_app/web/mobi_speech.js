// 연속(continuous) 음성 인식기. speech_to_text의 턴마다 stop/start 재시작이
// iOS Safari/인앱 브라우저에서 '무제스처 재시작 차단'에 걸려 두 번째 턴부터 인식이
// 씹히는 문제를 피하기 위해, 인식 세션을 한 번만 시작하고 턴 사이에 멈추지 않는다.
(() => {
  let recognition = null;
  let running = false;
  let wantRunning = false;
  let handlers = {};
  let lang = "ko-KR";

  function supported() {
    return !!(window.SpeechRecognition || window.webkitSpeechRecognition);
  }

  function setHandlers(onResult, onState) {
    handlers = { onResult, onState };
  }

  function _build() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    const rec = new SR();
    rec.lang = lang;
    rec.continuous = true;
    rec.interimResults = true;
    rec.maxAlternatives = 1;
    rec.onresult = (event) => {
      let interim = "";
      let finalText = "";
      for (let i = event.resultIndex; i < event.results.length; i += 1) {
        const r = event.results[i];
        if (r.isFinal) finalText += r[0].transcript;
        else interim += r[0].transcript;
      }
      if (handlers.onResult) {
        if (finalText) handlers.onResult(finalText, true);
        else if (interim) handlers.onResult(interim, false);
      }
    };
    rec.onend = () => {
      running = false;
      if (handlers.onState) handlers.onState("ended");
      // 브라우저가 임의로 세션을 끝낸 경우(특히 모바일) 자동으로 다시 시작한다.
      if (wantRunning) {
        try {
          rec.start();
          running = true;
          if (handlers.onState) handlers.onState("listening");
        } catch (_) {
          // 무제스처 재시작이 막히면 다음 사용자 탭(resume)에서 복구한다.
        }
      }
    };
    rec.onerror = (event) => {
      const err = (event && event.error) || "error";
      // no-speech/aborted는 onend의 자동 재시작으로 회복되므로 무시.
      if (err !== "no-speech" && err !== "aborted") {
        if (handlers.onState) handlers.onState("error:" + err);
      }
    };
    return rec;
  }

  // 사용자 제스처(버튼 탭) 컨텍스트에서 호출되어야 모바일에서 확실히 시작된다.
  function start(localeId) {
    if (!supported()) return false;
    if (localeId) lang = localeId.replace("_", "-");
    wantRunning = true;
    try {
      if (!recognition) recognition = _build();
      if (!running) {
        recognition.start();
        running = true;
        if (handlers.onState) handlers.onState("listening");
      }
      return true;
    } catch (_) {
      return running;
    }
  }

  // 자동 재시작이 막힌 뒤 사용자 탭으로 다시 시작.
  function resume() {
    if (!recognition) return start(lang);
    wantRunning = true;
    if (running) return true;
    try {
      recognition.start();
      running = true;
      if (handlers.onState) handlers.onState("listening");
      return true;
    } catch (_) {
      return false;
    }
  }

  function stop() {
    wantRunning = false;
    if (recognition) {
      try {
        recognition.onend = null;
        recognition.stop();
      } catch (_) {}
      try {
        recognition.abort && recognition.abort();
      } catch (_) {}
    }
    recognition = null;
    running = false;
  }

  window.MobiSpeech = {
    supported,
    setHandlers,
    start,
    resume,
    stop,
    isRunning: () => running,
  };
})();
