import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'firebase_auth_service.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.configurationReady,
    required this.builder,
    this.session,
    this.appLabel = 'MOBI',
  });

  final bool configurationReady;
  final Widget Function(BuildContext context, AuthAccount account) builder;
  final AuthSession? session;
  final String appLabel;

  @override
  Widget build(BuildContext context) {
    if (!configurationReady) {
      return _AuthMessagePage(
        title: 'Firebase 설정 필요',
        message:
            '이 Web 앱의 Firebase 설정이 없습니다. 새 Firebase 프로젝트에서 Web 앱을 등록하고 실행 설정을 전달해 주세요.',
      );
    }
    final auth = session ?? FirebaseAuthSession.instance;
    return StreamBuilder<AuthAccount?>(
      stream: auth.authStateChanges,
      initialData: auth.currentAccount,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _AuthMessagePage(
            title: '인증 상태 확인 실패',
            message: 'Firebase 인증 서비스에 연결할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.',
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        if (account == null) {
          return _SignInPage(session: auth, appLabel: appLabel);
        }
        final child = builder(context, account);
        if (!FirebaseAuthSession.localDemo) return child;
        return Column(
          children: [
            const Material(
              color: Colors.amber,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '로컬 시연 · 가상 버스/기사 · 실제 승차 판단에 사용하지 마세요',
                    style: TextStyle(color: Colors.black, fontSize: 14),
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
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
            'user-not-found' => '이메일 또는 비밀번호를 확인해 주세요.',
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
