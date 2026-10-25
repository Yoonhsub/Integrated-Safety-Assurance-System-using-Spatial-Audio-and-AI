import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../services/backend_api_client.dart';
import '../services/ride_creation_intent.dart';

/// The business ride UI uses the existing HTTP contract, never direct RTDB.
class RideRequestPanel extends StatefulWidget {
  const RideRequestPanel(
      {super.key,
      required this.api,
      required this.draft,
      this.session,
      this.store});
  final BackendApiClient api;
  final RideRequestDraft? draft;
  final AuthSession? session;
  final RideCreationIntentStore? store;

  @override
  State<RideRequestPanel> createState() => _RideRequestPanelState();
}

class _RideRequestPanelState extends State<RideRequestPanel> {
  late final AuthSession _auth;
  late final RideCreationIntentStore _store;
  StreamSubscription<AuthAccount?>? _subscription;
  String? _uid;
  String? _requestId;
  String _status = '요청 전';
  String _message = '버스를 선택한 뒤 탑승 요청을 보내세요.';
  bool _busy = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _auth = widget.session ?? FirebaseAuthSession.instance;
    _store = widget.store ?? RideCreationIntentStore();
    _uid = _auth.currentAccount?.uid;
    _subscription = _auth.authStateChanges.listen((account) {
      if (account?.uid != _auth.currentAccount?.uid) return;
      if (account?.uid == _uid) return;
      setState(() {
        _epoch++;
        _uid = account?.uid;
        _requestId = null;
        _status = '요청 전';
        _message = '현재 계정의 탑승 요청을 확인해 주세요.';
        _busy = false;
      });
      _restore();
    });
    _restore();
  }

  bool _current(int epoch, String? uid) =>
      mounted &&
      epoch == _epoch &&
      uid == _uid &&
      uid == _auth.currentAccount?.uid;

  Future<void> _restore() async {
    final uid = _uid;
    if (uid == null) return;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      final id = await _store.activeRequest(uid);
      if (!_current(epoch, uid) || id == null) return;
      _requestId = id;
      final result = await widget.api.fetchRideRequestStatus(requestId: id);
      if (_current(epoch, uid)) _show(result);
    } catch (_) {
      if (_current(epoch, uid)) {
        setState(() => _message = '요청 복구에 실패했습니다. 다시 조회해 주세요.');
      }
    } finally {
      if (_current(epoch, uid)) setState(() => _busy = false);
    }
  }

  void _show(RideRequestStatusResult result) {
    setState(() {
      _status = result.statusLabel;
      _message = result.description;
    });
  }

  Future<void> _create() async {
    if (_busy) return;
    final uid = _uid;
    final draft = widget.draft;
    if (uid == null || draft == null || draft.userId != uid) return;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      final key = await _store.begin(draft);
      if (!_current(epoch, uid)) return;
      final result =
          await widget.api.createRideRequest(draft: draft, idempotencyKey: key);
      if (!_current(epoch, uid)) return;
      setState(() {
        _message = result.description;
        // A failed retry must not replace the ID of an existing request.
        if (result.isSuccess) {
          _requestId = result.requestId;
          _status = result.statusLabel;
        }
      });
      if (result.isSuccess && result.requestId != null) {
        await _store.rememberRequest(uid, result.requestId!);
        await _store.complete(uid, key);
      }
    } catch (error) {
      if (_current(epoch, uid)) {
        setState(() => _message = error is StateError
            ? error.message.toString()
            : '요청에 실패했습니다. 같은 요청으로 다시 시도해 주세요.');
      }
    } finally {
      if (_current(epoch, uid)) setState(() => _busy = false);
    }
  }

  Future<void> _readOrCancel({bool cancel = false}) async {
    if (_busy) return;
    final id = _requestId;
    if (id == null) {
      await _restore();
      return;
    }
    final uid = _uid;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      final result = cancel
          ? await widget.api.cancelRideRequest(id)
          : await widget.api.fetchRideRequestStatus(requestId: id);
      if (_current(epoch, uid)) _show(result);
    } on AuthenticatedApiException catch (error) {
      if (_current(epoch, uid)) setState(() => _message = error.userMessage);
    } catch (_) {
      if (_current(epoch, uid)) {
        setState(() => _message = '통신에 실패했습니다. 상태를 다시 조회해 주세요.');
      }
    } finally {
      if (_current(epoch, uid)) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _epoch++;
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terminal = {'CANCELLED', 'COMPLETED'}.contains(_status);
    return Semantics(
        liveRegion: true,
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('탑승 요청 상태'),
                    Text(_busy ? '처리 중...' : _status,
                        key: const ValueKey('ride-status')),
                    Text(_message, key: const ValueKey('ride-message')),
                    if (_requestId != null)
                      SelectableText('요청 ID: $_requestId'),
                    ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(64),
                            textStyle: const TextStyle(fontSize: 20)),
                        onPressed: _busy ||
                                _uid == null ||
                                widget.draft == null ||
                                widget.draft?.userId != _uid ||
                                (_requestId != null && !terminal)
                            ? null
                            : _create,
                        child: const Text('탑승 요청하기')),
                    OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            textStyle: const TextStyle(fontSize: 18)),
                        onPressed: _busy || _uid == null
                            ? null
                            : () => _readOrCancel(),
                        child: const Text('상태 조회')),
                    OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            textStyle: const TextStyle(fontSize: 18)),
                        onPressed: _busy ||
                                _requestId == null ||
                                terminal ||
                                _uid == null
                            ? null
                            : () => _readOrCancel(cancel: true),
                        child: const Text('내 탑승 요청 취소')),
                  ],
                ))));
  }
}
