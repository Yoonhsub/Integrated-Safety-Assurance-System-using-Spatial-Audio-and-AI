import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'backend_api_client.dart';

/// Durable unresolved user action. No credentials are stored here.
class RideCreationIntentStore {
  String _slot(String uid) =>
      'mobi.ride.pending.v1.${Uri.encodeComponent(uid)}';

  String _activeSlot(String uid) =>
      'mobi.ride.active.v1.${Uri.encodeComponent(uid)}';

  Future<String?> activeRequest(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = prefs.getString(_activeSlot(uid));
    return id != null && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)
        ? id
        : null;
  }

  Future<void> rememberRequest(String uid, String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_activeSlot(uid), requestId)) {
      throw StateError('새로고침 복구 정보를 저장하지 못했습니다. 요청 ID: $requestId');
    }
  }

  Future<String> begin(RideRequestDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final slot = _slot(draft.userId);
    final body = jsonEncode(draft.toJson());
    final saved = prefs.getString(slot);
    if (saved != null) {
      final pending = jsonDecode(saved) as Map<String, dynamic>;
      if (pending['body'] != body) {
        throw StateError('이전 탑승 요청의 결과가 아직 확인되지 않았습니다. 이전 노선을 선택해 재시도해 주세요.');
      }
      return pending['key'] as String;
    }
    final random = Random.secure();
    final key = List.generate(
            24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    if (!await prefs.setString(slot, jsonEncode({'key': key, 'body': body}))) {
      throw StateError('재시도 정보를 저장할 수 없어 요청을 보내지 않았습니다.');
    }
    return key;
  }

  Future<void> complete(String uid, String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final saved = prefs.getString(_slot(uid));
    if (saved != null &&
        (jsonDecode(saved) as Map<String, dynamic>)['key'] == key) {
      await prefs.remove(_slot(uid));
    }
  }
}
