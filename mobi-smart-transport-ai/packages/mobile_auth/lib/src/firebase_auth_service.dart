import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_configuration.dart';
import 'auth_only_configuration.dart';

class AuthAccount {
  const AuthAccount({required this.uid, this.email});

  final String uid;
  final String? email;
}

abstract interface class AuthSession {
  Stream<AuthAccount?> get authStateChanges;
  AuthAccount? get currentAccount;
  Future<AuthAccount> signIn(String email, String password);
  Future<void> signOut();
  Future<String?> getIdToken({bool forceRefresh = false});
  Future<Object?> getCustomClaim(String name, {bool forceRefresh = false});
}

class FirebaseAuthSession implements AuthSession {
  static const localDemo = bool.fromEnvironment('MOBI_LOCAL_DEMO');
  FirebaseAuthSession({FirebaseAuth? auth})
      : _auth = auth ?? FirebaseAuth.instance;

  static final FirebaseAuthSession instance = FirebaseAuthSession();
  final FirebaseAuth _auth;

  static Future<bool> initializeWebApp({
    FirebaseWebConfiguration? configuration,
    String? requiredRole,
  }) async {
    final config = configuration ?? FirebaseWebConfiguration.fromEnvironment();
    if (!config.isComplete) return false;
    const authOnly = AuthOnlyConfiguration.fromEnvironment();
    if (authOnly.enabled &&
        !authOnly.matchesWebConfiguration(config, requiredRole: requiredRole))
      return false;
    if (localDemo &&
        (!kIsWeb ||
            config.projectId != 'demo-mobi-local' ||
            !{'localhost', '127.0.0.1'}.contains(Uri.base.host))) return false;
    if (!localDemo && config.projectId.startsWith('demo-')) return false;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: config.toFirebaseOptions());
      }
      final initialized = Firebase.app().options;
      if (initialized.projectId != config.projectId ||
          initialized.appId != config.appId) return false;
      if (localDemo) {
        await FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 9099);
      }
      return true;
    } catch (_) {
      // Do not continue into the app with a partially initialized auth client.
      return false;
    }
  }

  AuthAccount? _account(User? user) =>
      user == null ? null : AuthAccount(uid: user.uid, email: user.email);

  @override
  Stream<AuthAccount?> get authStateChanges =>
      _auth.authStateChanges().map(_account);

  @override
  AuthAccount? get currentAccount => _account(_auth.currentUser);

  @override
  Future<AuthAccount> signIn(String email, String password) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = credential.user;
    if (user == null) throw StateError('Firebase login returned no user.');
    return AuthAccount(uid: user.uid, email: user.email);
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return user.getIdToken(forceRefresh);
  }

  @override
  Future<Object?> getCustomClaim(
    String name, {
    bool forceRefresh = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final result = await user.getIdTokenResult(forceRefresh);
    return result.claims?[name];
  }
}
