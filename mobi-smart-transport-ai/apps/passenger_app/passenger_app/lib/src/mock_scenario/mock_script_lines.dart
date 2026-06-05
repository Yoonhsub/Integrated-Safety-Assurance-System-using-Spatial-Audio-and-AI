class MockScriptLine {
  const MockScriptLine({
    required this.id,
    required this.text,
    this.assetFileName,
  });

  final String id;
  final String text;
  final String? assetFileName;

  String get assetPath => 'mock_voice/${assetFileName ?? '$id.mp3'}';
}

const Map<String, MockScriptLine> mockScriptLines = <String, MockScriptLine>{
  'mock_start': MockScriptLine(
    id: 'mock_start',
    text: 'Mock 안내를 시작합니다. 이어폰의 좌우 방향감과 비프 간격을 확인해 주세요.',
  ),
  'arrive_at_stop': MockScriptLine(
    id: 'arrive_at_stop',
    text: '정류장 대기 위치에 도착했습니다. 안내 범위 안에서 기다려 주세요.',
  ),
  'bus_approaching': MockScriptLine(
    id: 'bus_approaching',
    text: '목표 버스가 접근하고 있습니다. 비프 소리를 따라 준비해 주세요.',
  ),
  'bus_stopped': MockScriptLine(
    id: 'bus_stopped',
    text: '목표 버스가 가까이 도착했습니다. 문 위치를 확인하고 탑승을 준비해 주세요.',
  ),
  'geofence_warning': MockScriptLine(
    id: 'geofence_warning',
    text: '정류장 대기 범위를 벗어났습니다. 안전한 대기 위치로 돌아가 주세요.',
  ),
  'wrong_bus_warning': MockScriptLine(
    id: 'wrong_bus_warning',
    text: '목표 버스가 아닙니다. 현재 버스에는 탑승하지 말고 기다려 주세요.',
  ),
  'boarding_prompt': MockScriptLine(
    id: 'boarding_prompt',
    text: '탑승 가능 상태입니다. 기사님과 문 위치를 확인한 뒤 천천히 탑승해 주세요.',
  ),
  'boarded_success': MockScriptLine(
    id: 'boarded_success',
    text: '탑승이 확인되었습니다. 안내를 종료합니다.',
  ),
  'missed_bus': MockScriptLine(
    id: 'missed_bus',
    text: '버스를 놓친 것으로 판단됩니다. 다음 도착 정보를 다시 확인하겠습니다.',
  ),
  'signal_lost': MockScriptLine(
    id: 'signal_lost',
    text: '비컨 신호가 끊겼습니다. 주변 위치와 버스 접근 상태를 다시 확인해 주세요.',
  ),
};

MockScriptLine? mockScriptLineById(String id) => mockScriptLines[id];
