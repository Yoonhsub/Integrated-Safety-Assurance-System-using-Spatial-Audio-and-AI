// V3 guidance data models

enum GuidanceState {
  idle,
  destinationSet,
  routeRecommended,
  routeSelected,
  navigatingToStop,
  arrivedAtStop,
  waitingForBus,
  busApproaching,
  boardingConfirmation,
  boarded,
  missedBus,
  replanNextBus,
}

GuidanceState guidanceStateFromString(String s) {
  const map = {
    'IDLE': GuidanceState.idle,
    'DESTINATION_SET': GuidanceState.destinationSet,
    'ROUTE_RECOMMENDED': GuidanceState.routeRecommended,
    'ROUTE_SELECTED': GuidanceState.routeSelected,
    'NAVIGATING_TO_STOP': GuidanceState.navigatingToStop,
    'ARRIVED_AT_STOP': GuidanceState.arrivedAtStop,
    'WAITING_FOR_BUS': GuidanceState.waitingForBus,
    'BUS_APPROACHING': GuidanceState.busApproaching,
    'BOARDING_CONFIRMATION': GuidanceState.boardingConfirmation,
    'BOARDED': GuidanceState.boarded,
    'MISSED_BUS': GuidanceState.missedBus,
    'REPLAN_NEXT_BUS': GuidanceState.replanNextBus,
  };
  return map[s] ?? GuidanceState.idle;
}

class GuidanceSession {
  final String sessionId;
  final String userId;
  final GuidanceState guidanceState;
  final String wakeWord;
  final String? destination;
  final String? selectedStopId;
  final String? selectedStopName;
  final String? selectedRouteNo;
  final String? targetBusId;
  final int? targetArrivalMinutes;
  final bool hasArrivedAtStop;
  final bool geofenceArmed;
  final String? nearestBeaconId;
  final String? nearestRouteNo;
  final String? lastDecision;
  final String? lastAiIntent;
  final String? lastMessage;
  final String? fallbackSource;

  const GuidanceSession({
    required this.sessionId,
    required this.userId,
    required this.guidanceState,
    required this.wakeWord,
    this.destination,
    this.selectedStopId,
    this.selectedStopName,
    this.selectedRouteNo,
    this.targetBusId,
    this.targetArrivalMinutes,
    required this.hasArrivedAtStop,
    required this.geofenceArmed,
    this.nearestBeaconId,
    this.nearestRouteNo,
    this.lastDecision,
    this.lastAiIntent,
    this.lastMessage,
    this.fallbackSource,
  });

  factory GuidanceSession.fromJson(Map<String, dynamic> json) {
    return GuidanceSession(
      sessionId: json['sessionId'] as String? ?? 'demo-session-001',
      userId: json['userId'] as String? ?? 'passenger-demo-001',
      guidanceState: guidanceStateFromString(json['guidanceState'] as String? ?? 'IDLE'),
      wakeWord: json['wakeWord'] as String? ?? '자비스',
      destination: json['destination'] as String?,
      selectedStopId: json['selectedStopId'] as String?,
      selectedStopName: json['selectedStopName'] as String?,
      selectedRouteNo: json['selectedRouteNo'] as String?,
      targetBusId: json['targetBusId'] as String?,
      targetArrivalMinutes: json['targetArrivalMinutes'] as int?,
      hasArrivedAtStop: json['hasArrivedAtStop'] as bool? ?? false,
      geofenceArmed: json['geofenceArmed'] as bool? ?? false,
      nearestBeaconId: json['nearestBeaconId'] as String?,
      nearestRouteNo: json['nearestRouteNo'] as String?,
      lastDecision: json['lastDecision'] as String?,
      lastAiIntent: json['lastAiIntent'] as String?,
      lastMessage: json['lastMessage'] as String?,
      fallbackSource: json['fallbackSource'] as String?,
    );
  }
}

class ConverseResponse {
  final bool recognizedWakeWord;
  final String intent;
  final Map<String, dynamic> slots;
  final String guidanceState;
  final String message;
  final bool shouldSpeak;
  final String ttsMode;
  final Map<String, dynamic>? cue;
  final Map<String, dynamic>? debug;

  const ConverseResponse({
    required this.recognizedWakeWord,
    required this.intent,
    required this.slots,
    required this.guidanceState,
    required this.message,
    required this.shouldSpeak,
    required this.ttsMode,
    this.cue,
    this.debug,
  });

  factory ConverseResponse.fromJson(Map<String, dynamic> json) {
    return ConverseResponse(
      recognizedWakeWord: json['recognizedWakeWord'] as bool? ?? false,
      intent: json['intent'] as String? ?? 'UNKNOWN',
      slots: (json['slots'] as Map<String, dynamic>?) ?? {},
      guidanceState: json['guidanceState'] as String? ?? 'IDLE',
      message: json['message'] as String? ?? '',
      shouldSpeak: json['shouldSpeak'] as bool? ?? true,
      ttsMode: json['ttsMode'] as String? ?? 'GEMINI_TTS',
      cue: json['cue'] as Map<String, dynamic>?,
      debug: json['debug'] as Map<String, dynamic>?,
    );
  }
}
