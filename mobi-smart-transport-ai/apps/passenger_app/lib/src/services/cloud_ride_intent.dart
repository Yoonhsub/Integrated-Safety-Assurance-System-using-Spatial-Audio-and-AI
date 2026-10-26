import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backend_api_client.dart';
import 'ride_creation_intent.dart';

/// The normal random intent store is unchanged. Verification uses one reviewed
/// action and a data-run-scoped recovery slot; no tokens/passwords are stored.
class CloudRideIntentStore extends RideCreationIntentStore {
  CloudRideIntentStore(this.plan);
  final CloudRidePlan plan;
  String _slot(String uid) => 'mobi.cloud.ride.${plan.dataRun}.active.$uid';
  void _check(String uid) {
    plan.validate();
    if (!{plan.uid('passenger-a'), plan.uid('passenger-b')}.contains(uid)) {
      throw const AuthenticatedApiException(403);
    }
  }

  @override
  Future<String> begin(RideRequestDraft draft) async {
    plan.validate();
    plan.validateDraft(draft.toJson());
    return plan.idempotencyKey;
  }

  @override
  Future<String?> activeRequest(String uid) async {
    _check(uid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = prefs.getString(_slot(uid));
    if (id != null && id != plan.requestId) {
      throw StateError('Stored request is outside the reviewed data run');
    }
    return id;
  }

  @override
  Future<void> rememberRequest(String uid, String requestId) async {
    _check(uid);
    if (uid != plan.uid('passenger-a') || requestId != plan.requestId) {
      throw const AuthenticatedApiException(403);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_slot(uid), requestId)) {
      throw StateError('Could not persist reviewed request ID');
    }
  }

  @override
  Future<void> complete(String uid, String key) async {
    _check(uid);
    if (key != plan.idempotencyKey) {
      throw const AuthenticatedApiException(403);
    }
    // The single reviewed key remains stable, including after a lost response.
  }
}
