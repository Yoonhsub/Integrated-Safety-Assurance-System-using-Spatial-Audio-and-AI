import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

void main() {
  FirebaseWebConfiguration config(
          {String appId = '1:123456:android:abcdef',
          String sender = '123456',
          String domain = ''}) =>
      FirebaseWebConfiguration(
          apiKey: 'public-test-key',
          appId: appId,
          messagingSenderId: sender,
          projectId: 'example-project',
          authDomain: domain);
  test('Android config works without a Web auth domain', () {
    expect(config().isCompleteForAndroid, true);
    expect(config().toFirebaseOptions().authDomain, isNull);
    expect(config().isComplete, false);
  });
  test('Web app ID cannot initialize the Android app', () {
    expect(
        config(appId: '1:123456:web:abcdef', domain: 'example.test')
            .isCompleteForAndroid,
        false);
    expect(
        config(appId: '1:123456:web:abcdef', domain: 'example.test').isComplete,
        true);
  });
  test('Android sender must match app registration', () {
    expect(config(sender: '999999').isCompleteForAndroid, false);
  });
}
