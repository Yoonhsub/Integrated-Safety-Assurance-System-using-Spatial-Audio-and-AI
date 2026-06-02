// 관대한 옵션의 raw navigator.geolocation 래퍼.
// geolocator 플러그인의 엄격한 호출(고정확도/짧은 timeout)이 인앱 브라우저 등에서
// 실패할 때, maximumAge로 캐시된 위치라도 빠르게 돌려받기 위한 폴백.
(() => {
  function getPosition() {
    return new Promise((resolve) => {
      if (!navigator.geolocation) {
        resolve(null);
        return;
      }
      navigator.geolocation.getCurrentPosition(
        (pos) => resolve({
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          acc: pos.coords.accuracy || 0,
        }),
        () => resolve(null),
        { enableHighAccuracy: false, timeout: 15000, maximumAge: 60000 },
      );
    });
  }
  window.MobiGeo = { getPosition };
})();
