import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/widgets/app_navigation.dart';

void main() {
  testWidgets(
      'common navigation remains above every page; back differs from home',
      (t) async {
    final observer = AppNavigationObserver();
    final key = GlobalKey<NavigatorState>();
    var homes = 0;
    await t.pumpWidget(MaterialApp(
        navigatorKey: key,
        navigatorObservers: [observer],
        builder: (context, child) => AppNavigationBar(
            observer: observer,
            atHome: false,
            onHome: () => homes++,
            child: child!),
        home: const Scaffold(body: Text('root'))));
    final initialBack = t.getTopLeft(find.text('뒤로 가기'));
    key.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('camera'))));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('뒤로 가기')), initialBack);
    await t.tap(find.text('뒤로 가기'));
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
    expect(homes, 0);
    key.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('test'))));
    await t.pumpAndSettle();
    await t.tap(find.text('홈으로 가기'));
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
    expect(homes, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('home does not force past a page exit guard', (t) async {
    final observer = AppNavigationObserver();
    final key = GlobalKey<NavigatorState>();
    var homes = 0;
    await t.pumpWidget(MaterialApp(
        navigatorKey: key,
        navigatorObservers: [observer],
        builder: (context, child) => AppNavigationBar(
            observer: observer,
            atHome: false,
            onHome: () => homes++,
            child: child!),
        home: const Scaffold(body: Text('root'))));
    key.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const PopScope(
            canPop: false, child: Scaffold(body: Text('guarded')))));
    await t.pumpAndSettle();
    await t.tap(find.text('홈으로 가기'));
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
    expect(find.text('guarded'), findsOneWidget);
    expect(homes, 0);
    await t.pumpWidget(const SizedBox());
  });
}
