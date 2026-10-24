import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'auth_only_configuration.dart';
import 'firebase_auth_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.configurationReady,
    required this.builder,
    this.session,
    this.appLabel = 'MOBI',
    this.requiredRole,
    this.authOnly = const AuthOnlyConfiguration.fromEnvironment(),
  });

  final bool configurationReady;
  final Widget Function(BuildContext context, AuthAccount account) builder;
  final AuthSession? session;
  final String appLabel;
  final String? requiredRole;
  final AuthOnlyConfiguration authOnly;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthSession? _auth;
  StreamSubscription<AuthAccount?>? _subscription;
  AuthAccount? _account;
  _CheckedClaims? _claims;
  int _source = 0;
  int _generation = 0;
  bool _checking = false;
  bool _signingOut = false;
  // Survives duplicate auth events and failed sign-out attempts.
  String? _logoutUid;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.configurationReady != widget.configurationReady ||
        oldWidget.requiredRole != widget.requiredRole ||
        oldWidget.authOnly.enabled != widget.authOnly.enabled ||
        oldWidget.authOnly.projectId != widget.authOnly.projectId ||
        oldWidget.authOnly.runId != widget.authOnly.runId) {
      _bind();
    }
  }

  void _cancelSubscription() {
    final old = _subscription;
    _subscription = null;
    if (old != null) {
      unawaited(old.cancel().catchError((Object _) {
        debugPrint('Auth state subscription cleanup failed');
      }));
    }
  }

  void _bind() {
    _source++;
    _generation++;
    _cancelSubscription();
    _account = null;
    _claims = null;
    _error = null;
    _checking = false;
    _signingOut = false;
    if (!widget.configurationReady || !widget.authOnly.isValid) {
      _auth = null;
      return;
    }
    final auth = widget.session ?? FirebaseAuthSession.instance;
    _auth = auth;
    final source = _source;
    _receive(auth.currentAccount);
    _subscription = auth.authStateChanges.listen((account) {
      if (mounted && source == _source) _receive(account);
    }, onError: (Object _) {
      if (!mounted || source != _source) return;
      _generation++;
      setState(() {
        _checking = false;
        _signingOut = false;
        _claims = null;
        _error = '인증 상태를 확인할 수 없습니다. 다시 로그인해 주세요.';
      });
    });
  }

  void _receive(AuthAccount? account) {
    // A queued event must agree with the current SDK session. In particular,
    // an old signed-out event must not erase a newly signed-in account.
    if (account?.uid != _auth?.currentAccount?.uid) return;
    // Claims epochs may change independently of logout intent. A repeated
    // same-user event is not evidence that the user requested a new login.
    if (_logoutUid != null && account?.uid == _logoutUid) return;
    // A confirmed signed-out state or a different account ends this intent.
    _logoutUid = null;
    final generation = ++_generation;
    setState(() {
      _account = account;
      _claims = null;
      _error = null;
      _signingOut = false;
      _checking = account != null &&
          (widget.requiredRole != null || widget.authOnly.enabled);
    });
    if (_checking) {
      unawaited(_check(account!, generation, _source));
    }
  }

  bool _current(AuthAccount account, int generation, int source) =>
      mounted &&
      generation == _generation &&
      source == _source &&
      _logoutUid != account.uid &&
      _auth?.currentAccount?.uid == account.uid;

  Future<void> _check(AuthAccount account, int generation, int source) async {
    final auth = _auth!;
    try {
      final role = await auth.getCustomClaim('mobi_role', forceRefresh: true);
      if (!_current(account, generation, source)) return;
      if (role is! String ||
          !{'passenger', 'driver'}.contains(role) ||
          (widget.requiredRole != null && role != widget.requiredRole)) {
        throw StateError('role');
      }
      final observedRun = widget.authOnly.enabled
          ? await auth.getCustomClaim('mobi_cloud_test_run')
          : null;
      if (!_current(account, generation, source)) return;
      final rawDriverId = (role == 'driver' || widget.authOnly.enabled)
          ? await auth.getCustomClaim('mobi_driver_id')
          : null;
      if (!_current(account, generation, source)) return;
      final driverId = rawDriverId is String ? rawDriverId : null;
      if (widget.authOnly.enabled &&
          rawDriverId != null &&
          rawDriverId is! String) {
        throw StateError('driver');
      }
      if (role == 'driver' &&
          (driverId == null ||
              driverId.isEmpty ||
              driverId.length > 128 ||
              RegExp(r'[.#$\[\]/\\\x00-\x1f\x7f]').hasMatch(driverId))) {
        throw StateError('driver');
      }
      if (widget.authOnly.enabled &&
          !widget.authOnly.accepts(account.uid, role, observedRun, driverId)) {
        throw StateError('run');
      }
      setState(() {
        _claims = _CheckedClaims(role, driverId);
        _checking = false;
      });
    } catch (_) {
      if (!_current(account, generation, source)) return;
      setState(() {
        _claims = null;
        _checking = false;
        _error = '이 앱에 접근할 권한이 없거나 계정 정보를 확인할 수 없습니다.';
      });
    }
  }

  Future<void> _signOut() async {
    if (_signingOut || _auth == null) return;
    // Invalidate pending work before the asynchronous sign-out begins.
    final generation = ++_generation;
    final source = _source;
    _logoutUid = _auth!.currentAccount?.uid ?? _account?.uid;
    setState(() {
      _signingOut = true;
      _claims = null;
      _checking = false;
      _error = '로그아웃 중';
    });
    try {
      await _auth!.signOut();
      if (!mounted || source != _source || generation != _generation) return;
      if (_auth!.currentAccount == null) {
        _receive(null);
      } else {
        setState(() {
          _signingOut = false;
          _error = '로그아웃 상태를 확인할 수 없습니다. 다시 시도해 주세요.';
        });
      }
    } catch (_) {
      if (!mounted || source != _source || generation != _generation) return;
      setState(() {
        _signingOut = false;
        _error = '로그아웃하지 못했습니다. 다시 시도해 주세요.';
      });
    }
  }

  @override
  void dispose() {
    _source++;
    _generation++;
    _cancelSubscription();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.configurationReady) {
      return const _AuthMessagePage(
        title: 'Firebase 설정 필요',
        message: '이 Web 앱의 Firebase 설정이 없습니다. 실행 설정을 확인해 주세요.',
      );
    }
    if (!widget.authOnly.isValid) {
      return const _AuthMessagePage(
        title: '인증 테스트 설정 오류',
        message: '승인된 테스트 프로젝트와 runId가 필요합니다.',
      );
    }
    if (_error != null) {
      return _AccountStatusPage(
        title: '계정 접근 차단',
        message: _error!,
        onSignOut: _signingOut ? null : _signOut,
      );
    }
    final account = _account;
    if (account == null) {
      return _SignInPage(session: _auth!, appLabel: widget.appLabel);
    }
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (widget.authOnly.enabled) {
      final claims = _claims;
      if (claims == null) return const SizedBox.shrink();
      return Scaffold(
        appBar: AppBar(title: Text('${widget.appLabel} 인증 확인')),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('인증 전용 테스트 · Backend 데이터 요청 없음'),
          SelectableText('Project ID: ${widget.authOnly.projectId}'),
          SelectableText('UID: ${account.uid}'),
          SelectableText('이메일: ${account.email ?? ""}'),
          SelectableText('mobi_role: ${claims.role}'),
          SelectableText('mobi_cloud_test_run: ${widget.authOnly.runId}'),
          if (claims.driverId != null)
            SelectableText('mobi_driver_id: ${claims.driverId}'),
          const SizedBox(height: 20),
          FilledButton(onPressed: _signOut, child: const Text('로그아웃')),
        ])),
      );
    }
    final child = widget.builder(context, account);
    if (!FirebaseAuthSession.localDemo) return child;
    return Column(children: [
      const Material(
          color: Colors.amber,
          child: SafeArea(
              bottom: false,
              child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('로컬 시연 · 가상 버스/기사 · 실제 승차 판단에 사용하지 마세요',
                      style: TextStyle(color: Colors.black, fontSize: 14))))),
      Expanded(child: child),
    ]);
  }
}

class _CheckedClaims {
  const _CheckedClaims(this.role, this.driverId);
  final String role;
  final String? driverId;
}

class _AccountStatusPage extends StatelessWidget {
  const _AccountStatusPage(
      {required this.title, required this.message, this.onSignOut});
  final String title;
  final String message;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) => Scaffold(
          body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title),
          Text(message, textAlign: TextAlign.center),
          FilledButton(onPressed: onSignOut, child: const Text('로그아웃')),
        ]),
      ));
}

class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.session, required this.appLabel});

  final AuthSession session;
  final String appLabel;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.signIn(
        _emailController.text,
        _passwordController.text,
      );
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error.code) {
            'invalid-credential' ||
            'wrong-password' ||
            'user-not-found' =>
              '이메일 또는 비밀번호를 확인해 주세요.',
            'user-disabled' => '비활성화된 계정입니다. 관리자에게 문의해 주세요.',
            'network-request-failed' => '네트워크 연결을 확인해 주세요.',
            _ => '로그인할 수 없습니다. 계정 상태를 확인해 주세요.',
          };
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '로그인할 수 없습니다. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${widget.appLabel} 로그인',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text('관리자가 사전 등록한 계정으로 로그인하세요.'),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: '이메일'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _signIn(),
                      decoration: const InputDecoration(labelText: '비밀번호'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _signIn,
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('로그인'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _AuthMessagePage extends StatelessWidget {
  const _AuthMessagePage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
}
