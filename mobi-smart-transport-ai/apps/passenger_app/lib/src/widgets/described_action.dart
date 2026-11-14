import 'dart:async';
import 'package:flutter/material.dart';
import '../services/speech_priority_coordinator.dart';

class ActionSpeechScope extends InheritedWidget {
  const ActionSpeechScope(
      {super.key, required this.speech, required super.child});
  final SpeechPriorityCoordinator speech;
  static SpeechPriorityCoordinator of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ActionSpeechScope>()?.speech ??
      sharedSpeechPriority;
  @override
  bool updateShouldNotify(ActionSpeechScope oldWidget) =>
      speech != oldWidget.speech;
}

/// Only explicitly marked functional actions use touch confirmation.
/// Accessibility activation is one semantic action, never two raw taps.
class DescribedAction extends StatefulWidget {
  const DescribedAction(
      {super.key,
      required this.label,
      required this.description,
      required this.onActivate,
      required this.child,
      this.immediate = false});
  factory DescribedAction.button(
          {Key? key,
          required String label,
          required String description,
          required ButtonStyleButton child,
          bool immediate = false}) =>
      DescribedAction(
          key: key,
          label: label,
          description: description,
          onActivate: child.onPressed,
          immediate: immediate,
          child: child);
  factory DescribedAction.icon(
          {Key? key,
          required String label,
          required String description,
          required IconButton child,
          bool immediate = false}) =>
      DescribedAction(
          key: key,
          label: label,
          description: description,
          onActivate: child.onPressed,
          immediate: immediate,
          child: child);
  final String label, description;
  final VoidCallback? onActivate;
  final Widget child;
  final bool immediate;
  static void cancelDescriptions() {
    for (final state
        in List<_DescribedActionState>.of(_DescribedActionState.active)) {
      state.cancel();
    }
  }

  @override
  State<DescribedAction> createState() => _DescribedActionState();
}

class _DescribedActionState extends State<DescribedAction>
    with WidgetsBindingObserver {
  static final active = <_DescribedActionState>{};
  static _DescribedActionState? armed;
  final owner = Object();
  Timer? timer;
  int generation = 0;
  bool executing = false, foreground = true;
  SpeechPriorityCoordinator? speech;
  bool get current =>
      mounted && foreground && (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
    active.add(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ActionSpeechScope.of(context);
    if (speech != null && speech != next) cancel();
    speech = next;
    if (MediaQuery.accessibleNavigationOf(context) || !current) cancel();
  }

  @override
  void didUpdateWidget(DescribedAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label ||
        oldWidget.description != widget.description ||
        widget.onActivate == null ||
        oldWidget.onActivate != widget.onActivate ||
        oldWidget.immediate != widget.immediate) {
      cancel();
    }
  }

  Future<void> stopDescription() async {
    try {
      await speech?.stopObservation(owner);
    } catch (_) {/* Action remains available. */}
  }

  void cancel() {
    generation++;
    timer?.cancel();
    if (identical(armed, this)) armed = null;
    unawaited(stopDescription());
  }

  Future<void> describe(int ticket) async {
    try {
      await speech?.speakObservation(
          owner,
          widget.description,
          () =>
              current &&
              ticket == generation &&
              !executing &&
              !MediaQuery.accessibleNavigationOf(context));
    } catch (_) {/* TTS failure must not execute an action. */}
  }

  void executeAction() {
    if (!current || widget.onActivate == null || executing) return;
    DescribedAction.cancelDescriptions();
    // Emergency actions never wait for speech cancellation acknowledgement.
    if (widget.immediate) {
      widget.onActivate!();
      return;
    }
    executing = true;
    final ticket = generation;
    unawaited(() async {
      await stopDescription();
      if (current && ticket == generation && widget.onActivate != null) {
        widget.onActivate!();
      }
      executing = false;
    }());
  }

  void tap() {
    if (!current || widget.onActivate == null) return;
    if (widget.immediate ||
        MediaQuery.accessibleNavigationOf(context) ||
        identical(armed, this)) {
      executeAction();
      return;
    }
    DescribedAction.cancelDescriptions();
    armed = this;
    timer = Timer(const Duration(milliseconds: 500), () {
      if (identical(armed, this)) armed = null;
    });
    unawaited(describe(++generation));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) cancel();
  }

  @override
  void deactivate() {
    cancel();
    super.deactivate();
  }

  @override
  void dispose() {
    cancel();
    active.remove(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: widget.onActivate != null,
        label: widget.label,
        hint: widget.description,
        onTap: widget.onActivate == null ? null : executeAction,
        excludeSemantics: true,
        child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onActivate == null ? null : tap,
            child: IgnorePointer(child: widget.child)),
      );
}
