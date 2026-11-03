import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_driver_app/src/app.dart';

void main() {
  testWidgets('driver app fails closed when web Firebase config is absent',
      (tester) async {
    await tester.pumpWidget(const MobiApp());

    expect(find.text('Firebase 설정 필요'), findsOneWidget);
    expect(find.text('로그인'), findsNothing);
  });
}
