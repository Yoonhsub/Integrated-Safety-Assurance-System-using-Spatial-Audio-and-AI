// 관대한 옵션의 raw navigator.geolocation 래퍼.
// geolocator 플러그인의 엄격한 호출(고정확도/짧은 timeout)이 인앱 브라우저 등에서
// 실패할 때를 대비한 폴백 + 지속 watch.
//
// 설계 의도:
//  - watchPosition으로 권한이 있는 동안 최신 좌표를 계속 캐시한다(일회성 실패로
//    좌표가 비는 '들쭉날쭉' 제거). 한 번 시작하면 세션 내내 갱신된다.
//  - 마지막 에러(code/message)를 보존해 앱이 실패 원인(권한 거부/위치 불가/타임아웃)을
//    확인할 수 있게 한다(예전엔 에러를 통째로 삼켜 원인을 알 수 없었다).
(() => {
  let last = null;        // { lat, lng, acc, ts }
  let lastError = null;   // { code, message }
  let watchId = null;

  function _opts(highAccuracy) {
    return {
      enableHighAccuracy: !!highAccuracy,
      timeout: 15000,
      maximumAge: 60000,
    };
  }

  function _onPos(pos) {
    last = {
      lat: pos.coords.latitude,
      lng: pos.coords.longitude,
      acc: pos.coords.accuracy || 0,
      ts: Date.now(),
    };
    lastError = null;
  }

  function _onErr(err) {
    // code: 1 PERMISSION_DENIED, 2 POSITION_UNAVAILABLE, 3 TIMEOUT
    lastError = {
      code: (err && typeof err.code === "number") ? err.code : -1,
      message: (err && err.message) || "geolocation error",
    };
  }

  // 일회성 즉시 획득(사용자 제스처 직후 등). 성공 시 캐시도 갱신.
  function getPosition() {
    return new Promise((resolve) => {
      if (!navigator.geolocation) {
        lastError = { code: -2, message: "geolocation unsupported" };
        resolve(null);
        return;
      }
      navigator.geolocation.getCurrentPosition(
        (pos) => { _onPos(pos); resolve({ lat: last.lat, lng: last.lng, acc: last.acc }); },
        (err) => { _onErr(err); resolve(null); },
        _opts(false),
      );
    });
  }

  // 지속 추적 시작(한 번만). 권한이 있으면 첫 fix가 도착하는 즉시 캐시에 채워지고
  // 이동/시간에 따라 계속 갱신된다.
  function startWatch() {
    if (!navigator.geolocation || watchId !== null) return;
    try {
      watchId = navigator.geolocation.watchPosition(_onPos, _onErr, _opts(true));
    } catch (_) {
      watchId = null;
    }
  }

  function getCached() { return last; }         // { lat, lng, acc, ts } | null
  function getLastError() { return lastError; }  // { code, message } | null

  window.MobiGeo = { getPosition, startWatch, getCached, getLastError };
})();
