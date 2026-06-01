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
    this.routePlan,
  });

  final String sessionId;
  final String intent;
  final String state;
  final String message;
  final String ttsMode;
  final V3Cue cue;
  final bool usedGemini;
  final String fallbackSource;
  final V3RoutePlanResponse? routePlan;

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
      routePlan: V3RoutePlanResponse.fromNullableJson(_mapValue(json['routePlan'])),
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

class V3RoutePlanResponse {
  const V3RoutePlanResponse({
    required this.status,
    required this.readiness,
    required this.heardText,
    required this.plans,
    required this.alternatives,
    required this.fallbackSource,
    this.warnings = const <String>[],
    this.destination,
    this.recommendedPlan,
    this.agentMessage,
    this.question,
  });

  final String status;
  final String readiness;
  final String heardText;
  final V3DestinationResolveResponse? destination;
  final List<V3RoutePlanCandidate> plans;
  final List<V3RoutePlanCandidate> alternatives;
  final V3RoutePlanCandidate? recommendedPlan;
  final String? agentMessage;
  final String? question;
  final String fallbackSource;
  final List<String> warnings;

  factory V3RoutePlanResponse.fromJson(Map<String, dynamic> json) {
    final rawPlans = json['plans'];
    final rawAlternatives = json['alternatives'];
    return V3RoutePlanResponse(
      status: _stringValue(json['status'], fallback: 'NOT_FOUND'),
      readiness: _stringValue(json['readiness'], fallback: 'ERROR'),
      heardText: _stringValue(json['heardText'], fallback: ''),
      destination: V3DestinationResolveResponse.fromNullableJson(_mapValue(json['destination'])),
      plans: rawPlans is List
          ? rawPlans
              .whereType<Map>()
              .map((item) => V3RoutePlanCandidate.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const <V3RoutePlanCandidate>[],
      alternatives: rawAlternatives is List
          ? rawAlternatives
              .whereType<Map>()
              .map((item) => V3RoutePlanCandidate.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const <V3RoutePlanCandidate>[],
      recommendedPlan: V3RoutePlanCandidate.fromNullableJson(_mapValue(json['recommendedPlan'])),
      agentMessage: _nullableString(json['agentMessage']),
      question: _nullableString(json['question']),
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
      warnings: _stringList(json['warnings']),
    );
  }

  static V3RoutePlanResponse? fromNullableJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return V3RoutePlanResponse.fromJson(json);
  }
}

class V3DestinationResolveResponse {
  const V3DestinationResolveResponse({
    required this.status,
    required this.candidates,
    this.topCandidate,
    this.question,
  });

  final String status;
  final V3DestinationCandidate? topCandidate;
  final List<V3DestinationCandidate> candidates;
  final String? question;

  static V3DestinationResolveResponse? fromNullableJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final rawCandidates = json['candidates'];
    return V3DestinationResolveResponse(
      status: _stringValue(json['status'], fallback: 'NOT_FOUND'),
      topCandidate: V3DestinationCandidate.fromNullableJson(_mapValue(json['topCandidate'])),
      candidates: rawCandidates is List
          ? rawCandidates
              .whereType<Map>()
              .map((item) => V3DestinationCandidate.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const <V3DestinationCandidate>[],
      question: _nullableString(json['question']),
    );
  }
}

class V3DestinationCandidate {
  const V3DestinationCandidate({
    required this.name,
    required this.type,
    required this.confidence,
  });

  final String name;
  final String type;
  final double confidence;

  factory V3DestinationCandidate.fromJson(Map<String, dynamic> json) {
    return V3DestinationCandidate(
      name: _stringValue(json['name'], fallback: ''),
      type: _stringValue(json['type'], fallback: 'PLACE'),
      confidence: _doubleValue(json['confidence']),
    );
  }

  static V3DestinationCandidate? fromNullableJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return V3DestinationCandidate.fromJson(json);
  }
}

class V3RoutePlanCandidate {
  const V3RoutePlanCandidate({
    required this.planId,
    required this.type,
    required this.destinationName,
    required this.summary,
    required this.boardingInstruction,
    required this.transferCount,
    required this.totalBusStopCount,
    required this.estimatedWalkMeters,
    required this.accessibilityScore,
    required this.simplicityScore,
    required this.score,
    required this.segments,
    required this.fallbackSource,
    this.planSource = 'LOCAL_FALLBACK',
    this.provider = 'LOCAL',
    this.verificationStatus = 'LOCAL_ONLY',
    this.warnings = const <String>[],
    this.totalEstimatedMinutes,
    this.recommendedReason,
    this.rankingEvidence = const <String>[],
  });

  final String planId;
  final String type;
  final String destinationName;
  final String summary;
  final String boardingInstruction;
  final int transferCount;
  final int totalBusStopCount;
  final double estimatedWalkMeters;
  final double accessibilityScore;
  final double simplicityScore;
  final double score;
  final int? totalEstimatedMinutes;
  final String? recommendedReason;
  final List<String> rankingEvidence;
  final List<V3RoutePlanSegment> segments;
  final String fallbackSource;
  final String planSource;
  final String provider;
  final String verificationStatus;
  final List<String> warnings;

  factory V3RoutePlanCandidate.fromJson(Map<String, dynamic> json) {
    final rawSegments = json['segments'];
    return V3RoutePlanCandidate(
      planId: _stringValue(json['planId'], fallback: ''),
      type: _stringValue(json['type'], fallback: 'DIRECT'),
      destinationName: _stringValue(json['destinationName'], fallback: ''),
      summary: _stringValue(json['summary'], fallback: ''),
      boardingInstruction: _stringValue(json['boardingInstruction'], fallback: ''),
      transferCount: _intValue(json['transferCount']),
      totalBusStopCount: _intValue(json['totalBusStopCount']),
      estimatedWalkMeters: _doubleValue(json['estimatedWalkMeters']),
      accessibilityScore: _doubleValue(json['accessibilityScore']),
      simplicityScore: _doubleValue(json['simplicityScore']),
      score: _doubleValue(json['score']),
      totalEstimatedMinutes: _nullableInt(json['totalEstimatedMinutes']),
      recommendedReason: _nullableString(json['recommendedReason']),
      rankingEvidence: _stringList(json['rankingEvidence']),
      segments: rawSegments is List
          ? rawSegments
              .whereType<Map>()
              .map((item) => V3RoutePlanSegment.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : const <V3RoutePlanSegment>[],
      fallbackSource: _stringValue(json['fallbackSource'], fallback: 'MOCK'),
      planSource: _stringValue(json['planSource'], fallback: 'LOCAL_FALLBACK'),
      provider: _stringValue(json['provider'], fallback: 'LOCAL'),
      verificationStatus: _stringValue(json['verificationStatus'], fallback: 'LOCAL_ONLY'),
      warnings: _stringList(json['warnings']),
    );
  }

  static V3RoutePlanCandidate? fromNullableJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return V3RoutePlanCandidate.fromJson(json);
  }
}

class V3RoutePlanSegment {
  const V3RoutePlanSegment({
    required this.routeNo,
    required this.routeId,
    required this.boardStop,
    required this.alightStop,
    required this.stopCount,
    required this.arrivals,
    required this.arrivalSource,
    required this.arrivalUnknown,
    this.source = 'LOCAL',
    this.providerRouteId,
    this.boardingStopNodeId,
    this.alightingStopNodeId,
    this.estimatedMinutes,
    this.directionHint,
  });

  final String routeNo;
  final String routeId;
  final V3RoutePlanStop boardStop;
  final V3RoutePlanStop alightStop;
  final int stopCount;
  final String? directionHint;
  final List<V3BusArrival> arrivals;
  final String arrivalSource;
  final bool arrivalUnknown;
  final String source;
  final String? providerRouteId;
  final String? boardingStopNodeId;
  final String? alightingStopNodeId;
  final int? estimatedMinutes;

  factory V3RoutePlanSegment.fromJson(Map<String, dynamic> json) {
    final rawArrivals = json['arrivals'];
    return V3RoutePlanSegment(
      routeNo: _stringValue(json['routeNo'], fallback: ''),
      routeId: _stringValue(json['routeId'], fallback: ''),
      boardStop: V3RoutePlanStop.fromJson(_mapValue(json['boardStop']) ?? const <String, dynamic>{}),
      alightStop: V3RoutePlanStop.fromJson(_mapValue(json['alightStop']) ?? const <String, dynamic>{}),
      stopCount: _intValue(json['stopCount']),
      directionHint: _nullableString(json['directionHint']),
      arrivals: rawArrivals is List
          ? rawArrivals
              .whereType<Map>()
              .map((item) => V3BusArrival.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const <V3BusArrival>[],
      arrivalSource: _stringValue(json['arrivalSource'], fallback: 'MOCK'),
      arrivalUnknown: json['arrivalUnknown'] == true,
      source: _stringValue(json['source'], fallback: 'LOCAL'),
      providerRouteId: _nullableString(json['providerRouteId']),
      boardingStopNodeId: _nullableString(json['boardingStopNodeId']),
      alightingStopNodeId: _nullableString(json['alightingStopNodeId']),
      estimatedMinutes: _nullableInt(json['estimatedMinutes']),
    );
  }
}

class V3RoutePlanStop {
  const V3RoutePlanStop({
    required this.stopId,
    required this.stopName,
    this.latitude,
    this.longitude,
    this.distanceMeters,
    this.order,
    this.directionHint,
    this.sideHint,
    required this.visionRequiredForSideHint,
    this.crossStreetHint,
    this.nodeId,
  });

  final String stopId;
  final String stopName;
  final double? latitude;
  final double? longitude;
  final double? distanceMeters;
  final int? order;
  final String? directionHint;
  final String? sideHint;
  final bool visionRequiredForSideHint;
  final String? crossStreetHint;
  final String? nodeId;

  factory V3RoutePlanStop.fromJson(Map<String, dynamic> json) {
    return V3RoutePlanStop(
      stopId: _stringValue(json['stopId'], fallback: ''),
      stopName: _stringValue(json['stopName'], fallback: ''),
      latitude: _nullableDouble(json['latitude']),
      longitude: _nullableDouble(json['longitude']),
      distanceMeters: _nullableDouble(json['distanceMeters']),
      order: _nullableInt(json['order']),
      directionHint: _nullableString(json['directionHint']),
      sideHint: _nullableString(json['sideHint']),
      visionRequiredForSideHint: json['visionRequiredForSideHint'] == true,
      crossStreetHint: _nullableString(json['crossStreetHint']),
      nodeId: _nullableString(json['nodeId']),
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

  static V3PublicBusStopEvidence? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return V3PublicBusStopEvidence(
      datasetName: _stringValue(json['datasetName'], fallback: ''),
      endpoint: _stringValue(json['endpoint'], fallback: ''),
      serviceId: _stringValue(json['serviceId'], fallback: ''),
      stopName: _stringValue(json['stopName'], fallback: ''),
      longitude: _doubleValue(json['longitude']),
      latitude: _doubleValue(json['latitude']),
      fetchedAt: _stringValue(json['fetchedAt'], fallback: ''),
      totalCount: _intValue(json['totalCount']),
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

  static V3RoutePlanningEvidence? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final rawArrivals = json['arrivals'];
    return V3RoutePlanningEvidence(
      source: _stringValue(json['source'], fallback: 'ERROR'),
      stopId: _stringValue(json['stopId'], fallback: ''),
      stopName: _stringValue(json['stopName'], fallback: ''),
      routeNo: _stringValue(json['routeNo'], fallback: ''),
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

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.map((item) => item.toString()).toList();
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
