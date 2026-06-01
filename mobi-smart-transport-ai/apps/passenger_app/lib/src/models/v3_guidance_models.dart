class V3Cue {
  const V3Cue({
    required this.type,
    required this.ttsMode,
    required this.shouldVibrate,
    required this.shouldBeep,
    this.message,
  });

  final String type;
  final String ttsMode;
  final bool shouldVibrate;
  final bool shouldBeep;
  final String? message;

  bool get isNone => type == 'NONE';
  bool get isSafetyLocal => ttsMode == 'SAFETY_LOCAL';
  bool get needsLocalPlayback =>
      ttsMode == 'SAFETY_LOCAL' || ttsMode == 'LOCAL_TTS';

  factory V3Cue.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const V3Cue(
        type: 'NONE',
        ttsMode: 'NONE',
        shouldVibrate: false,
        shouldBeep: false,
      );
    }

    return V3Cue(
      type: _stringValue(json['type'], fallback: 'NONE'),
      ttsMode: _stringValue(json['ttsMode'], fallback: 'NONE'),
      shouldVibrate: json['shouldVibrate'] == true,
      shouldBeep: json['shouldBeep'] == true,
      message: _nullableString(json['message']),
    );
  }
}

class V3GuidanceState {
  const V3GuidanceState({
    required this.sessionId,
    required this.state,
    required this.wakeWord,
    required this.geofenceArmed,
    required this.updatedAt,
    this.selectedDestination,
    this.selectedRouteNo,
    this.selectedRouteId,
    this.selectedStopId,
    this.selectedStopName,
    this.targetBusId,
    this.lastDecision,
    this.nearestBeacon,
    this.targetBus,
  });

  final String sessionId;
  final String state;
  final String wakeWord;
  final bool geofenceArmed;
  final DateTime? updatedAt;
  final String? selectedDestination;
  final String? selectedRouteNo;
  final String? selectedRouteId;
  final String? selectedStopId;
  final String? selectedStopName;
  final String? targetBusId;
  final String? lastDecision;
  final Map<String, dynamic>? nearestBeacon;
  final Map<String, dynamic>? targetBus;

  factory V3GuidanceState.fromJson(Map<String, dynamic> json) {
    return V3GuidanceState(
      sessionId: _stringValue(json['sessionId'], fallback: 'demo-session'),
      state: _stringValue(json['state'], fallback: 'IDLE'),
      wakeWord: _stringValue(json['wakeWord'], fallback: '자비스'),
      geofenceArmed: json['geofenceArmed'] == true,
      updatedAt: _dateTimeValue(json['updatedAt']),
      selectedDestination: _nullableString(json['selectedDestination']),
      selectedRouteNo: _nullableString(json['selectedRouteNo']),
      selectedRouteId: _nullableString(json['selectedRouteId']),
      selectedStopId: _nullableString(json['selectedStopId']),
      selectedStopName: _nullableString(json['selectedStopName']),
      targetBusId: _nullableString(json['targetBusId']),
      lastDecision: _nullableString(json['lastDecision']),
      nearestBeacon: _mapValue(json['nearestBeacon']),
      targetBus: _mapValue(json['targetBus']),
    );
  }
}

class V3AgentResponse {
  const V3AgentResponse({
    required this.sessionId,
    required this.intent,
    required this.state,
    required this.message,
    required this.ttsMode,
    required this.cue,
    required this.usedGemini,
    required this.fallbackSource,
  });

  final String sessionId;
  final String intent;
  final String state;
  final String message;
  final String ttsMode;
  final V3Cue cue;
  final bool usedGemini;
  final String fallbackSource;

  factory V3AgentResponse.fromJson(Map<String, dynamic> json) {
    return V3AgentResponse(
      sessionId: _stringValue(json['sessionId'], fallback: 'demo-session'),
      intent: _stringValue(json['intent'], fallback: 'UNKNOWN'),
      state: _stringValue(json['state'], fallback: 'IDLE'),
      message: _stringValue(json['message'], fallback: '응답 메시지가 없습니다.'),
      ttsMode: _stringValue(json['ttsMode'], fallback: 'LOCAL_TTS'),
      cue: V3Cue.fromJson(_mapValue(json['cue'])),
      usedGemini: json['usedGemini'] == true,
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
    );
  }
}

class V3RouteRecommendation {
  const V3RouteRecommendation({
    required this.destination,
    required this.stopId,
    required this.stopName,
    required this.routeNo,
    required this.routeId,
    required this.confidence,
    required this.fallbackSource,
  });

  final String destination;
  final String stopId;
  final String stopName;
  final String routeNo;
  final String routeId;
  final double confidence;
  final String fallbackSource;

  factory V3RouteRecommendation.fromJson(Map<String, dynamic> json) {
    return V3RouteRecommendation(
      destination: _stringValue(json['destination'], fallback: ''),
      stopId: _stringValue(json['stopId'], fallback: ''),
      stopName: _stringValue(json['stopName'], fallback: ''),
      routeNo: _stringValue(json['routeNo'], fallback: ''),
      routeId: _stringValue(json['routeId'], fallback: ''),
      confidence: _doubleValue(json['confidence']),
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
    );
  }
}

class V3RouteRecommendResponse {
  const V3RouteRecommendResponse({
    required this.recommendations,
    required this.fallbackSource,
    required this.usedGemini,
    this.planningModel,
    this.planningSummary,
    this.planningDataSource,
    required this.mapsGrounded,
    required this.mapsEvidence,
    this.stopEvidence,
    this.evidence,
  });

  final List<V3RouteRecommendation> recommendations;
  final String fallbackSource;
  final bool usedGemini;
  final String? planningModel;
  final String? planningSummary;
  final String? planningDataSource;
  final bool mapsGrounded;
  final List<V3MapsGroundingEvidence> mapsEvidence;
  final V3PublicBusStopEvidence? stopEvidence;
  final V3RoutePlanningEvidence? evidence;

  factory V3RouteRecommendResponse.fromJson(Map<String, dynamic> json) {
    final rawRecommendations = json['recommendations'];
    return V3RouteRecommendResponse(
      recommendations: rawRecommendations is List
          ? rawRecommendations
              .whereType<Map>()
              .map((item) => V3RouteRecommendation.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const <V3RouteRecommendation>[],
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
      usedGemini: json['usedGemini'] == true,
      planningModel: _nullableString(json['planningModel']),
      planningSummary: _nullableString(json['planningSummary']),
      planningDataSource: _nullableString(json['planningDataSource']),
      mapsGrounded: json['mapsGrounded'] == true,
      mapsEvidence: _mapsEvidenceList(json['mapsEvidence']),
      stopEvidence: V3PublicBusStopEvidence.fromJson(_mapValue(json['stopEvidence'])),
      evidence: V3RoutePlanningEvidence.fromJson(_mapValue(json['evidence'])),
    );
  }
}

class V3MapsGroundingEvidence {
  const V3MapsGroundingEvidence({
    required this.title,
    required this.uri,
    this.placeId,
  });

  final String title;
  final String uri;
  final String? placeId;

  factory V3MapsGroundingEvidence.fromJson(Map<String, dynamic> json) {
    return V3MapsGroundingEvidence(
      title: _stringValue(json['title'], fallback: 'Google Maps 장소'),
      uri: _stringValue(json['uri'], fallback: ''),
      placeId: _nullableString(json['placeId']),
    );
  }
}

class V3PublicBusStopEvidence {
  const V3PublicBusStopEvidence({
    required this.datasetName,
    required this.endpoint,
    required this.serviceId,
    required this.stopName,
    required this.longitude,
    required this.latitude,
    required this.fetchedAt,
    required this.totalCount,
  });

  final String datasetName;
  final String endpoint;
  final String serviceId;
  final String stopName;
  final double longitude;
  final double latitude;
  final String fetchedAt;
  final int totalCount;

  factory V3PublicBusStopEvidence.fromJson(Map<String, dynamic>? json) {
    return V3PublicBusStopEvidence(
      datasetName: _stringValue(json?['datasetName'], fallback: ''),
      endpoint: _stringValue(json?['endpoint'], fallback: ''),
      serviceId: _stringValue(json?['serviceId'], fallback: ''),
      stopName: _stringValue(json?['stopName'], fallback: ''),
      longitude: _doubleValue(json?['longitude']),
      latitude: _doubleValue(json?['latitude']),
      fetchedAt: _stringValue(json?['fetchedAt'], fallback: ''),
      totalCount: _intValue(json?['totalCount']),
    );
  }
}

class V3RoutePlanningEvidence {
  const V3RoutePlanningEvidence({
    required this.source,
    required this.stopId,
    required this.stopName,
    required this.routeNo,
    required this.arrivals,
  });

  final String source;
  final String stopId;
  final String stopName;
  final String routeNo;
  final List<V3BusArrival> arrivals;

  bool get isPublicData => source == 'PUBLIC_API' || source == 'CACHE';

  factory V3RoutePlanningEvidence.fromJson(Map<String, dynamic>? json) {
    final rawArrivals = json?['arrivals'];
    return V3RoutePlanningEvidence(
      source: _stringValue(json?['source'], fallback: 'ERROR'),
      stopId: _stringValue(json?['stopId'], fallback: ''),
      stopName: _stringValue(json?['stopName'], fallback: ''),
      routeNo: _stringValue(json?['routeNo'], fallback: ''),
      arrivals: rawArrivals is List
          ? rawArrivals
              .whereType<Map>()
              .map((item) => V3BusArrival.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const <V3BusArrival>[],
    );
  }
}

List<V3MapsGroundingEvidence> _mapsEvidenceList(Object? value) {
  if (value is! List) return const <V3MapsGroundingEvidence>[];
  return value
      .whereType<Map>()
      .map((item) => V3MapsGroundingEvidence.fromJson(
            Map<String, dynamic>.from(item),
          ))
      .toList();
}

class V3BusArrival {
  const V3BusArrival({
    required this.routeNo,
    required this.stopId,
    required this.arrivalMinutes,
    this.busId,
    this.routeId,
    this.remainingStops,
    this.lowFloor,
    this.congestion,
  });

  final String? busId;
  final String routeNo;
  final String? routeId;
  final String stopId;
  final int arrivalMinutes;
  final int? remainingStops;
  final bool? lowFloor;
  final String? congestion;

  String get displayLabel {
    final bus = busId == null || busId!.isEmpty ? '' : ' · $busId';
    final stops = remainingStops == null ? '' : ' · $remainingStops정류장 전';
    return '$routeNo번 $arrivalMinutes분 뒤$stops$bus';
  }

  factory V3BusArrival.fromJson(Map<String, dynamic> json) {
    return V3BusArrival(
      busId: _nullableString(json['busId']),
      routeNo: _stringValue(json['routeNo'], fallback: ''),
      routeId: _nullableString(json['routeId']),
      stopId: _stringValue(json['stopId'], fallback: ''),
      arrivalMinutes: _intValue(json['arrivalMinutes']),
      remainingStops: _nullableInt(json['remainingStops']),
      lowFloor: json['lowFloor'] is bool ? json['lowFloor'] as bool : null,
      congestion: _nullableString(json['congestion']),
    );
  }
}

class V3BusArrivalsResponse {
  const V3BusArrivalsResponse({
    required this.stopId,
    required this.arrivals,
    required this.fallbackSource,
    this.routeNo,
  });

  final String stopId;
  final String? routeNo;
  final List<V3BusArrival> arrivals;
  final String fallbackSource;

  factory V3BusArrivalsResponse.fromJson(Map<String, dynamic> json) {
    final rawArrivals = json['arrivals'];
    return V3BusArrivalsResponse(
      stopId: _stringValue(json['stopId'], fallback: ''),
      routeNo: _nullableString(json['routeNo']),
      arrivals: rawArrivals is List
          ? rawArrivals
              .whereType<Map>()
              .map((item) => V3BusArrival.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const <V3BusArrival>[],
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
    );
  }
}

class V3MockGeofenceResponse {
  const V3MockGeofenceResponse({
    required this.sessionId,
    required this.state,
    required this.geofenceArmed,
    required this.cue,
    required this.message,
  });

  final String sessionId;
  final String state;
  final bool geofenceArmed;
  final V3Cue cue;
  final String message;

  factory V3MockGeofenceResponse.fromJson(Map<String, dynamic> json) {
    return V3MockGeofenceResponse(
      sessionId: _stringValue(json['sessionId'], fallback: 'demo-session'),
      state: _stringValue(json['state'], fallback: 'IDLE'),
      geofenceArmed: json['geofenceArmed'] == true,
      cue: V3Cue.fromJson(_mapValue(json['cue'])),
      message: _stringValue(json['message'], fallback: '상태 메시지가 없습니다.'),
    );
  }
}

class V3BeaconSignal {
  const V3BeaconSignal({
    required this.busId,
    this.routeNo,
    this.rssi,
    this.distanceMeters,
  });

  final String busId;
  final String? routeNo;
  final int? rssi;
  final double? distanceMeters;

  Map<String, Object?> toJson() => <String, Object?>{
        'busId': busId,
        if (routeNo != null && routeNo!.isNotEmpty) 'routeNo': routeNo,
        if (rssi != null) 'rssi': rssi,
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
      };

  factory V3BeaconSignal.fromJson(Map<String, dynamic> json) {
    return V3BeaconSignal(
      busId: _stringValue(json['busId'], fallback: ''),
      routeNo: _nullableString(json['routeNo']),
      rssi: _nullableInt(json['rssi']),
      distanceMeters: _nullableDouble(json['distanceMeters']),
    );
  }
}

class V3BeaconDecisionResponse {
  const V3BeaconDecisionResponse({
    required this.sessionId,
    required this.decision,
    required this.cue,
    required this.message,
    this.nearestBeacon,
    this.targetBus,
  });

  final String sessionId;
  final String decision;
  final V3BeaconSignal? nearestBeacon;
  final V3BeaconSignal? targetBus;
  final V3Cue cue;
  final String message;

  factory V3BeaconDecisionResponse.fromJson(Map<String, dynamic> json) {
    final nearest = _mapValue(json['nearestBeacon']);
    final target = _mapValue(json['targetBus']);
    return V3BeaconDecisionResponse(
      sessionId: _stringValue(json['sessionId'], fallback: 'demo-session'),
      decision: _stringValue(json['decision'], fallback: 'NO_BEACON'),
      nearestBeacon: nearest == null ? null : V3BeaconSignal.fromJson(nearest),
      targetBus: target == null ? null : V3BeaconSignal.fromJson(target),
      cue: V3Cue.fromJson(_mapValue(json['cue'])),
      message: _stringValue(json['message'], fallback: '비컨 판별 메시지가 없습니다.'),
    );
  }
}

class HeadTrackingDebugSnapshot {
  const HeadTrackingDebugSnapshot({
    required this.statusLabel,
    required this.isAvailable,
    this.yaw,
    this.pitch,
    this.roll,
    this.updatedAt,
  });

  final String statusLabel;
  final bool isAvailable;
  final double? yaw;
  final double? pitch;
  final double? roll;
  final DateTime? updatedAt;

  factory HeadTrackingDebugSnapshot.disabled() {
    return const HeadTrackingDebugSnapshot(
      statusLabel: 'optional · 센서 미연결',
      isAvailable: false,
    );
  }

  factory HeadTrackingDebugSnapshot.mock({
    double yaw = 0,
    double pitch = 0,
    double roll = 0,
  }) {
    return HeadTrackingDebugSnapshot(
      statusLabel: 'debug mock',
      isAvailable: true,
      yaw: yaw,
      pitch: pitch,
      roll: roll,
      updatedAt: DateTime.now(),
    );
  }
}

String _stringValue(Object? value, {required String fallback}) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int _intValue(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _nullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double _doubleValue(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

double? _nullableDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

DateTime? _dateTimeValue(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

Map<String, dynamic>? _mapValue(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}
