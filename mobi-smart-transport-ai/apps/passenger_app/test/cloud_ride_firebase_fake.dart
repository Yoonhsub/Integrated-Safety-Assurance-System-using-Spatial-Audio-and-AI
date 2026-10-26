// SDK platform interfaces are used only by this offline test double.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_protected_member
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

FirebaseWebConfiguration testWeb(String role) => FirebaseWebConfiguration(
    apiKey: 'AIzaSyAfKjXX3LtVE9iaVmcSjXKxl0VIu1x6hAU',
    appId: role == 'driver'
        ? '1:189730626159:web:b486ec4c18abf663170b9a'
        : '1:189730626159:web:407d25db8c026703170b9a',
    messagingSenderId: '189730626159',
    projectId: CloudRidePlan.project,
    authDomain: 'mobi-auth-cloud-test.firebaseapp.com');

class OfflineFirebaseState {
  String role = 'passenger';
  String? uid;
  String run = CloudRidePlan.authRun;
  String? driver;
  int refreshes = 0, signIns = 0, signOuts = 0;
  Completer<void>? refreshDelay, signOutDelay;
  final events = StreamController<UserPlatform?>.broadcast(sync: true);
  void switchUser(String? suffix) {
    uid = suffix == null ? null : 'ct-${CloudRidePlan.authRun}-$suffix';
    role = suffix?.startsWith('driver') == true ? 'driver' : 'passenger';
    driver = role == 'driver'
        ? 'ct-${CloudRidePlan.authRun}-driver-${suffix == 'driver-a' ? '502' : '105'}'
        : null;
    events.add(uid == null ? null : _User());
  }
}

class OfflineFirebase {
  static late OfflineFirebaseState state;
  static void install() {
    state = OfflineFirebaseState();
    FirebasePlatform.instance = _Core();
    FirebaseAuthPlatform.instance = _Auth();
  }

  static FirebaseAuthSession sessionForRole(String role) => FirebaseAuthSession(
      auth: firebase.FirebaseAuth.instanceFor(
          app: Firebase.app(role == 'passenger'
              ? '[DEFAULT]'
              : role == 'driver'
                  ? 'offline-driver'
                  : 'offline-wrong')));
}

class _Core extends FirebasePlatform {
  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) {
    final config = testWeb(name == 'offline-driver' ? 'driver' : 'passenger');
    final options = name == 'offline-wrong'
        ? const FirebaseOptions(
            apiKey: 'offline',
            appId: 'offline',
            messagingSenderId: 'offline',
            projectId: 'wrong-project')
        : config.toFirebaseOptions();
    return FirebaseAppPlatform(name, options);
  }

  @override
  List<FirebaseAppPlatform> get apps => [app()];
}

class _Auth extends FirebaseAuthPlatform {
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseAuthPlatform setInitialValues(
          {PigeonUserDetails? currentUser, String? languageCode}) =>
      this;
  @override
  UserPlatform? get currentUser =>
      OfflineFirebase.state.uid == null ? null : _User();
  @override
  Stream<UserPlatform?> authStateChanges() =>
      OfflineFirebase.state.events.stream;
  @override
  Future<void> signOut() async {
    OfflineFirebase.state.signOuts++;
    await OfflineFirebase.state.signOutDelay?.future;
    OfflineFirebase.state.switchUser(null);
  }

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
      String email, String password) async {
    final suffix = email.split('@').first;
    if (!{'passenger-a', 'passenger-b', 'driver-a', 'driver-b'}
        .contains(suffix)) {
      throw StateError('Unknown offline fixture account');
    }
    OfflineFirebase.state.signIns++;
    OfflineFirebase.state.switchUser(suffix);
    return _Credential(auth: this, user: currentUser);
  }
}

class _Credential extends UserCredentialPlatform {
  _Credential({required super.auth, super.user});
}

class _User extends Fake
    with MockPlatformInterfaceMixin
    implements UserPlatform {
  @override
  String get uid => OfflineFirebase.state.uid!;
  @override
  String get email => '$uid@example.test';
  @override
  Future<String?> getIdToken(bool forceRefresh) async {
    final originalUid = uid;
    if (forceRefresh) OfflineFirebase.state.refreshes++;
    if (forceRefresh) await OfflineFirebase.state.refreshDelay?.future;
    return 'offline|$originalUid|${OfflineFirebase.state.refreshes}';
  }

  @override
  Future<IdTokenResult> getIdTokenResult(bool forceRefresh) async =>
      IdTokenResult(PigeonIdTokenResult(claims: {
        'mobi_role': OfflineFirebase.state.role,
        'mobi_cloud_test_run': OfflineFirebase.state.run,
        if (OfflineFirebase.state.driver != null)
          'mobi_driver_id': OfflineFirebase.state.driver,
      }));
}
