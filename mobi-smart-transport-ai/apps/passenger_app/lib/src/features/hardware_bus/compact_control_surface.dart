import 'package:flutter/material.dart';

/// Accessibility-only enlarged controls. Sensor owners remain outside this view.
class CompactControlSurface extends StatefulWidget {
  const CompactControlSurface(
      {super.key,
      required this.label,
      required this.child,
      this.expandInPage = false});
  final String label;
  final Widget child;
  final bool expandInPage;
  @override
  State<CompactControlSurface> createState() => _CompactControlSurfaceState();
}

class _CompactControlSurfaceState extends State<CompactControlSurface> {
  final _revision = ValueNotifier<int>(0);
  @override
  void didUpdateWidget(covariant CompactControlSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revision.value++;
    });
  }

  Future<void> _open() {
    if (widget.expandInPage) {
      return Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (routeContext) => Scaffold(
            key: const ValueKey('compact-control-surface-page'),
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: Text(widget.label),
              leading: BackButton(
                key: const ValueKey('compact-control-surface-page-close'),
                onPressed: () => Navigator.pop(routeContext),
              ),
            ),
            body: SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: _revision,
                    builder: (_, __, ___) => widget.child,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('${widget.label} 확대 보기'),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: ValueListenableBuilder<int>(
                          valueListenable: _revision,
                          builder: (_, __, ___) => widget.child))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final enlarged = media.textScaler.scale(14) > 20 || media.size.height < 650;
    if (!enlarged) return widget.child;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.label),
                FilledButton(onPressed: _open, child: const Text('확대 보기')),
                const Text('큰 글씨 제어는 대화상자에서 확인하세요. 센서 동작은 유지됩니다.'),
              ],
            )));
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }
}
