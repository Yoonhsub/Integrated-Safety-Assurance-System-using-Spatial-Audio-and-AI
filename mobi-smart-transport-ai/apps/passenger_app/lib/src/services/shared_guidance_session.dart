import '../models/v3_guidance_models.dart';
import 'v3_agent_api_client.dart';

/// Memory-only route continuity. Never retains credentials, audio, BLE or leases.
class SharedGuidanceSession {
  String? _owner;
  int _generation = 0;
  Future<V3GuidanceState>? _opening;
  V3GuidanceState? state;
  V3RoutePlanResponse? routePlan;
  int get generation => _generation;

  void bind(String owner) {
    if (_owner != owner) {
      clear();
      _owner = owner;
    }
  }

  void clear() {
    _generation++;
    _opening = null;
    _owner = null;
    state = null;
    routePlan = null;
  }

  bool current(int generation) => _owner != null && generation == _generation;

  void save(int generation, V3GuidanceState? value, V3RoutePlanResponse? plan) {
    if (!current(generation)) return;
    state = value;
    routePlan = plan;
  }

  Future<V3GuidanceState> open({
    required Future<V3GuidanceState> Function() create,
    required Future<V3GuidanceState> Function(String) fetch,
  }) {
    final pending = _opening;
    if (pending != null) return pending;
    final generation = _generation;
    return _opening = _open(create: create, fetch: fetch).whenComplete(() {
      if (generation == _generation) _opening = null;
    });
  }

  Future<V3GuidanceState> _open({
    required Future<V3GuidanceState> Function() create,
    required Future<V3GuidanceState> Function(String) fetch,
  }) async {
    final generation = _generation;
    final previous = state;
    try {
      final result =
          previous == null ? await create() : await fetch(previous.sessionId);
      if (!current(generation)) throw StateError('Guidance owner changed');
      if (previous != null && result.sessionId != previous.sessionId) {
        clear();
        throw StateError('Guidance session mismatch');
      }
      if (previous != null &&
          (previous.selectedRouteId != result.selectedRouteId ||
           previous.selectedStopId != result.selectedStopId ||
           previous.selectedDestination != result.selectedDestination)) {
        routePlan = null;
      }
      state = result;
      return result;
    } on V3ApiException catch (error) {
      if (current(generation) &&
          {401, 403, 404, 410}.contains(error.statusCode)) {
        clear();
      }
      rethrow; // Never silently create a replacement for an expired session.
    }
  }
}
