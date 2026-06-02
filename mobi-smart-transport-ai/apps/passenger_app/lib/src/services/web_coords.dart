/// 웹에서 얻은 좌표(없으면 null로 표현).
class WebCoords {
  const WebCoords(this.latitude, this.longitude, this.accuracy);
  final double latitude;
  final double longitude;
  final double accuracy;
}
