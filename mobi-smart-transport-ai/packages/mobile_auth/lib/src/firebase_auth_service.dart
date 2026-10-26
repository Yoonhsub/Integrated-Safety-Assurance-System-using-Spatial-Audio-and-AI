import 'dart:async';
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
  // One epoch tracker per actual Auth delegate, shared by wrapper instances.
  static final _trackers = Expando<_FirebaseAuthEpoch>();
  _FirebaseAuthEpoch get _epochs {
    final existing = _trackers[_auth];
    if (existing != null && !existing.closed) return existing;
    return _trackers[_auth] = _FirebaseAuthEpoch(_auth);
  }

  /// Captures a request's immutable login generation, including same-UID logins.
  /// A stale guard is cancellation, never a reason to sign out a newer user.
  bool Function() captureRequestGuard() => _epochs.capture();

  /// Registration of this exact Auth delegate, including named Firebase apps.
  /// No credentials or token values are exposed.
  FirebaseWebConfiguration get webConfiguration {
    final options = _auth.app.options;
    return FirebaseWebConfiguration(
        apiKey: options.apiKey,
        appId: options.appId,
        messagingSenderId: options.messagingSenderId,
        projectId: options.projectId,
        authDomain: options.authDomain ?? '');
  }

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
  Stream<AuthAccount?> get authStateChanges {
    final epochs = _epochs;
    return Stream<AuthAccount?>.multi((controller) {
      final subscription = epochs.changes.stream.listen(
          (_) => controller.addSync(_account(epochs.visibleUser)),
          onDone: controller.close);
      controller.add(_account(epochs.visibleUser));
      controller.onCancel = subscription.cancel;
    }, isBroadcast: true);
  }

  @override
  AuthAccount? get currentAccount => _account(_epochs.visibleUser);

  @override
  Future<AuthAccount> signIn(String email, String password) =>
      _epochs.mutate(() async {
        final credential = await _auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        final user = credential.user;
        if (user == null) throw StateError('Firebase login returned no user.');
        return AuthAccount(uid: user.uid, email: user.email);
      }, login: true);

  @override
  Future<void> signOut() => _epochs.mutate(_auth.signOut, login: false);

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final user = _epochs.visibleUser;
    if (user == null) return null;
    return user.getIdToken(forceRefresh);
  }

  @override
  Future<Object?> getCustomClaim(
    String name, {
    bool forceRefresh = false,
  }) async {
    final user = _epochs.visibleUser;
    if (user == null) return null;
    final result = await user.getIdTokenResult(forceRefresh);
    return result.claims?[name];
  }
}

/// Application-level lifecycle, not a claim that remote requests can be undone.
class _FirebaseAuthEpoch {
  _FirebaseAuthEpoch(this.auth) : _lastUid = auth.currentUser?.uid {
    auth.authStateChanges().listen((user) {
      final uid = user?.uid;
      if (!_seenInitial && uid == _lastUid) {
        _seenInitial = true;
        return;
      }
      _seenInitial = true;
      _lastUid = uid;
      _generation++;
      // Emit a boundary even for an SDK event with the same UID. Explicit
      // mutations remain blocked until their serialized SDK operation completes.
      _transitioning = true;
      changes.add(_generation);
      _transitioning = false;
      changes.add(_generation);
    }, onDone: () {
      closed = true;
      _generation++;
      changes.close();
    });
  }
  final FirebaseAuth auth;
  final changes = StreamController<int>.broadcast(sync: true);
  Future<void> _tail = Future<void>.value();
  int _generation = 0, _pending = 0;
  bool _blocked = false, _transitioning = false, _seenInitial = false;
  bool closed = false;
  String? _lastUid;
  User? get visibleUser => closed || _blocked || _transitioning || _pending != 0
      ? null
      : auth.currentUser;

  bool Function() capture() {
    final generation = _generation;
    final uid = visibleUser?.uid;
    return () =>
        !closed &&
        !_blocked &&
        !_transitioning &&
        _pending == 0 &&
        generation == _generation &&
        uid == visibleUser?.uid;
  }

  Future<T> mutate<T>(Future<T> Function() action, {required bool login}) {
    _generation++;
    _pending++;
    _blocked = true;
    changes.add(_generation); // Invalidate before the first async/SDK wait.
    final operation = _tail.then((_) => action());
    final result = operation.then((value) {
      _finish(login);
      return value;
    }, onError: (Object error, StackTrace stack) {
      _finish(false);
      Error.throwWithStackTrace(error, stack);
    });
    // Serialize Auth mutations so a started signOut cannot finish after a later
    // signIn and erase it. A queued mutation already invalidates old requests.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _finish(bool loginSucceeded) {
    _pending--;
    if (_pending == 0) _blocked = !loginSucceeded;
    _lastUid = auth.currentUser?.uid;
    _generation++;
    changes.add(_generation);
  }
}
