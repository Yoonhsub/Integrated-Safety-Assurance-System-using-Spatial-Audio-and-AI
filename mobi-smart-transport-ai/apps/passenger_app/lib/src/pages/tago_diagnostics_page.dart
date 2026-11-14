import 'package:flutter/material.dart';
import '../services/tago_diagnostics_client.dart';

/// Explicit, read-only diagnostics against the configured authenticated backend.
class TagoDiagnosticsPage extends StatefulWidget {
  const TagoDiagnosticsPage(
      {super.key, required this.client, this.ownsClient = false});
  final TagoDiagnosticsClient client;
  final bool ownsClient;
  @override
  State<TagoDiagnosticsPage> createState() => _TagoDiagnosticsPageState();
}

class _TagoDiagnosticsPageState extends State<TagoDiagnosticsPage>
    with WidgetsBindingObserver {
  final _city = TextEditingController(),
      _stop = TextEditingController(),
      _route = TextEditingController();
  bool _busy = false;
  int _generation = 0, _view = 0;
  TagoDiagnosticResult? _result;
  String _request = '', _notice = '조회 버튼을 눌러야 요청합니다. 자동 조회하지 않습니다.';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _run(String action) async {
    if (_busy) return;
    final city = _city.text.trim(),
        stop = _stop.text.trim(),
        route = _route.text.trim();
    if (action != '상태' && city.isEmpty) {
      setState(() => _notice = '실제 도시 코드를 입력하세요.');
      return;
    }
    if ((action == '도착' && stop.isEmpty) || (action == '위치' && route.isEmpty)) {
      setState(() =>
          _notice = action == '도착' ? '실제 정류장 ID를 입력하세요.' : '실제 노선 ID를 입력하세요.');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _result = null;
      _view = 1;
      _request =
          '$action 조회 · 도시 입력: ${city.isEmpty ? "없음" : city} · 정류장: ${stop.isEmpty ? "없음" : stop} · 노선: ${route.isEmpty ? "없음" : route}';
      _notice = '요청 중';
    });
    try {
      final result = switch (action) {
        '상태' => await widget.client.health(),
        '도착' => await widget.client.arrivals(cityCode: city, stopId: stop),
        _ => await widget.client.locations(cityCode: city, routeId: route),
      };
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _notice = '';
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _notice = '요청 실패. 연결 및 로그인 상태를 확인한 뒤 직접 다시 조회하세요.');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _cancel() {
    ++_generation;
    if (mounted) {
      setState(() {
        _busy = false;
        _result = null;
        _notice = '조회 결과 수신을 중지했습니다. 다시 조회하려면 버튼을 누르세요.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _busy) _cancel();
  }

  String _classification(TagoDiagnosticStatus status) => switch (status) {
        TagoDiagnosticStatus.success => '응답 수신',
        TagoDiagnosticStatus.empty => '결과 0건 · 운행 없음의 증거 아님',
        TagoDiagnosticStatus.fallback => '대체 응답 · 실데이터 성공 아님',
        TagoDiagnosticStatus.unauthorized => '401 · 로그인/인증 필요',
        TagoDiagnosticStatus.forbidden => '403 · 접근 권한 없음',
        TagoDiagnosticStatus.unsupported => '현재 서버에서 지원하지 않는 조회',
        TagoDiagnosticStatus.invalidInput => '입력값 확인 필요',
        TagoDiagnosticStatus.timeout => '응답 시간 초과',
        TagoDiagnosticStatus.malformed => '응답 형식 확인 실패',
        TagoDiagnosticStatus.unavailable => '데이터 사용 불가',
        TagoDiagnosticStatus.error => '조회 오류',
      };
  Widget _inputs() => ListView(padding: const EdgeInsets.all(12), children: [
        const Text('조회 입력', style: TextStyle(fontSize: 20)),
        const Text(
            '실제 TAGO 도시 코드와 정류장·노선 ID를 입력하세요. 이 진단 API를 지원하지 않는 기존 서버는 지원하지 않음으로 표시합니다.'),
        TextField(
            controller: _city,
            maxLength: 6,
            keyboardType: TextInputType.number,
            enabled: !_busy,
            decoration: const InputDecoration(
                labelText: '실제 도시 코드', helperText: '예시값 자동 입력 없음')),
        TextField(
            controller: _stop,
            maxLength: 64,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '실제 정류장 ID')),
        TextField(
            controller: _route,
            maxLength: 64,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '실제 노선 ID')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(
              onPressed: _busy ? null : () => _run('상태'),
              child: const Text('서버 상태 조회')),
          FilledButton(
              onPressed: _busy ? null : () => _run('도착'),
              child: const Text('도착 조회')),
          OutlinedButton(
              onPressed: _busy ? null : () => _run('위치'),
              child: const Text('위치 조회')),
        ]),
        Text(_notice),
      ]);
  void _details(TagoDiagnosticResult result) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('응답 상세'),
            content: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.sizeOf(context).height * .6,
                child: ListView(children: [
                  Text(_request),
                  const Text('입력 ID가 실제 대상과 일치하는지 직접 확인하세요.'),
                  Text('출처: ${result.source} · 분류: ${result.status.name}'),
                  Text('HTTP: ${result.httpStatus?.toString() ?? "확인되지 않음"}'),
                  if (result.errorCode != null)
                    Text('서버 오류 코드: ${result.errorCode}'),
                  Text(
                      '원본 데이터 시각: ${result.updatedAt?.toIso8601String() ?? "제공되지 않음 · 신선도 확인 불가"}'),
                  Text(
                      '서버 조회 시각: ${result.fetchedAt?.toIso8601String() ?? "제공되지 않음"} (원본 관측 시각 아님)'),
                  Text(
                      '앱 수신 시각: ${result.receivedAt?.toIso8601String() ?? "수신되지 않음"} (원본 관측 시각 아님)'),
                  const Text(
                      '서버 상태 성공이나 HTTP 200만으로 실제 TAGO 데이터 성공을 확정하지 않습니다. MOCK/CACHE 대체 응답을 구분하세요.'),
                  const Text(
                      '위치 결과는 마지막 보고 정류장입니다. 실시간 GPS 위치나 실제 접근 여부를 뜻하지 않습니다.'),
                  for (final warning in result.warnings) Text('주의: $warning'),
                  Text(
                      '표시 레코드: ${result.records.length}건 / 전체: ${result.totalCount?.toString() ?? "미제공"}'),
                  if (result.truncated)
                    const Text('일부 레코드만 표시됩니다. 전체 결과로 해석하지 마세요.'),
                  for (var i = 0; i < result.records.length; i++)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: SelectableText(
                                '항목 ${i + 1}\n${result.records[i].entries.map((e) => "${e.key}: ${e.value}").join("\n")}'))),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('닫기'))
            ],
          ));
  Widget _results() {
    final result = _result;
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (_request.isEmpty) const Text('아직 조회하지 않았습니다.'),
      if (_busy) ...[
        const LinearProgressIndicator(semanticsLabel: '진단 요청 중'),
        OutlinedButton(onPressed: _cancel, child: const Text('결과 수신 중지')),
      ],
      if (_notice.isNotEmpty) Semantics(liveRegion: true, child: Text(_notice)),
      if (result != null) ...[
        Semantics(
            liveRegion: true,
            child: Text(_classification(result.status),
                style: const TextStyle(fontSize: 20))),
        Text(result.message),
        Text('출처: ${result.source}'),
        Text(
            '원본 데이터 시각: ${result.updatedAt?.toIso8601String() ?? "제공되지 않음 · 신선도 확인 불가"}'),
        Text(
            '앱 수신 시각: ${result.receivedAt?.toIso8601String() ?? "수신되지 않음"} (원본 관측 시각 아님)'),
        Text(
            '표시 ${result.records.length}건${result.truncated ? " · 일부 결과" : ""}'),
        const Text('HTTP 200만으로 실데이터 성공을 확정하지 않습니다.'),
        if (result.warnings.isNotEmpty)
          Text('주의: ${result.warnings.first}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
        OutlinedButton(
            onPressed: () => _details(result), child: const Text('응답 상세 보기')),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('TAGO 서버 진단')),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText('설정된 서버: ${widget.client.backendOrigin}')),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Expanded(
                    child: TextButton(
                        onPressed: () => setState(() => _view = 0),
                        child: const Text('1 입력'))),
                Expanded(
                    child: TextButton(
                        onPressed: () => setState(() => _view = 1),
                        child: const Text('2 결과'))),
              ])),
          Expanded(
              child: IndexedStack(
                  index: _view, children: [_inputs(), _results()])),
        ])),
      );
  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _city.dispose();
    _stop.dispose();
    _route.dispose();
    if (widget.ownsClient) widget.client.close();
    super.dispose();
  }
}
