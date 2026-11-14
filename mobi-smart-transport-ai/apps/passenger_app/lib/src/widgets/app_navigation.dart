import 'dart:async';
import 'package:flutter/material.dart';
import 'described_action.dart';

/// A single navigation row above the Navigator, including full-screen pages.
class AppNavigationObserver extends NavigatorObserver {
  final revision = ValueNotifier<int>(0);
  final routes = <Route<dynamic>>[];
  Completer<void>? _changed;
  void _notify() {
    _changed?.complete();
    _changed = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      revision.value++;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    _notify();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    _notify();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    _notify();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) routes[index] = newRoute;
    _notify();
  }

  Future<bool> back() async {
    final previous = routes.isEmpty ? null : routes.last;
    final changed = _changed ??= Completer<void>();
    if (navigator == null || !navigator!.canPop()) return false;
    await navigator!.maybePop(); // Honor camera/voice/test page exit guards.
    if (routes.isNotEmpty && routes.last == previous) {
      try {
        await changed.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        return false;
      }
    }
    return routes.isEmpty || routes.last != previous;
  }
}

class AppNavigationBar extends StatefulWidget {
  const AppNavigationBar(
      {super.key,
      required this.observer,
      required this.atHome,
      required this.onHome,
      required this.child});
  final AppNavigationObserver observer;
  final bool atHome;
  final VoidCallback onHome;
  final Widget child;
  @override
  State<AppNavigationBar> createState() => _AppNavigationBarState();
}

class _AppNavigationBarState extends State<AppNavigationBar> {
  bool navigating = false;
  Future<void> go(bool home) async {
    if (navigating) return;
    setState(() => navigating = true);
    DescribedAction.cancelDescriptions();
    final wasRoot = widget.observer.routes.length <= 1;
    try {
      if (widget.observer.routes.length > 1) {
        do {
          if (!await widget.observer.back()) return;
        } while (mounted && home && widget.observer.routes.length > 1);
      }
      if (mounted && (home || wasRoot)) widget.onHome();
    } finally {
      if (mounted) setState(() => navigating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFFF6F8FB),
        child: SafeArea(
            bottom: false,
            child: Column(children: [
              ValueListenableBuilder<int>(
                  valueListenable: widget.observer.revision,
                  builder: (context, _, __) {
                    final enabled = !navigating &&
                        (!widget.atHome || widget.observer.routes.length > 1);
                    return Row(children: [
                      TextButton.icon(
                          label: const Text('뒤로 가기'),
                          onPressed: enabled ? () => go(false) : null,
                          icon: const Icon(Icons.arrow_back)),
                      TextButton.icon(
                          label: const Text('홈으로 가기'),
                          onPressed: enabled ? () => go(true) : null,
                          icon: const Icon(Icons.home_outlined)),
                    ]);
                  }),
              Expanded(child: widget.child),
            ])),
      );
}
