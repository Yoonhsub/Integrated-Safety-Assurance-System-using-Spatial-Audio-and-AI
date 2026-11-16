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
      this.immediate = false,
      this.retapWindowAfterDescription = false});
  factory DescribedAction.button(
          {Key? key,
          required String label,
          required String description,
          required ButtonStyleButton child,
          bool immediate = false,
          bool retapWindowAfterDescription = false}) =>
      DescribedAction(
          key: key,
          label: label,
          description: description,
          onActivate: child.onPressed,
          immediate: immediate,
          retapWindowAfterDescription: retapWindowAfterDescription,
          child: child);
  factory DescribedAction.icon(
          {Key? key,
          required String label,
          required String description,
          required IconButton child,
          bool immediate = false,
          bool retapWindowAfterDescription = false}) =>
      DescribedAction(
          key: key,
          label: label,
          description: description,
          onActivate: child.onPressed,
          immediate: immediate,
          retapWindowAfterDescription: retapWindowAfterDescription,
          child: child);
  final String label, description;
  final VoidCallback? onActivate;
  final Widget child;
  final bool immediate, retapWindowAfterDescription;
  static void cancelDescriptions() {
    final pending = <_DescribedActionState>{};
    final armedAction = _DescribedActionState.armed;
    final speakingAction = _DescribedActionState.speaking;
    if (armedAction != null) pending.add(armedAction);
    if (speakingAction != null) pending.add(speakingAction);
    for (final state in pending) {
      state.cancel();
    }
  }

  @override
  State<DescribedAction> createState() => _DescribedActionState();
}

class _DescribedActionState extends State<DescribedAction>
    with WidgetsBindingObserver {
  static _DescribedActionState? armed;
  static _DescribedActionState? speaking;
  final owner = Object();
  Timer? timer;
  Future<void>? stopRequest;
  int generation = 0;
  bool executing = false, foreground = true;
  SpeechPriorityCoordinator? speech;
  bool get current =>
      mounted && foreground && (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
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
        oldWidget.immediate != widget.immediate ||
        oldWidget.retapWindowAfterDescription !=
            widget.retapWindowAfterDescription) {
      cancel();
    }
  }

  Future<void> stopDescription() async {
    if (!identical(speaking, this) && stopRequest == null) return;
    if (identical(speaking, this)) speaking = null;
    final existing = stopRequest;
    if (existing != null) {
      await existing;
      return;
    }
    try {
      final request = speech?.stopObservation(owner);
      if (request == null) return;
      stopRequest = request;
      await request;
    } catch (_) {/* Action remains available. */} finally {
      stopRequest = null;
    }
  }

  void cancel() {
    generation++;
    timer?.cancel();
    if (identical(armed, this)) armed = null;
    if (identical(speaking, this) || stopRequest != null) {
      unawaited(stopDescription());
    }
  }

  Future<void> describe(int ticket, {bool armAfterSpeech = false}) async {
    try {
      speaking = this;
      await speech?.speakObservation(
          owner,
          widget.description,
          () =>
              current &&
              ticket == generation &&
              !executing &&
              !MediaQuery.accessibleNavigationOf(context));
    } catch (_) {/* TTS failure must not execute an action. */} finally {
      if (identical(speaking, this)) speaking = null;
    }
    if (armAfterSpeech &&
        identical(armed, this) &&
        ticket == generation &&
        current) {
      timer?.cancel();
      timer = Timer(const Duration(milliseconds: 500), () {
        if (identical(armed, this)) armed = null;
      });
    }
  }

  void executeAction() {
    if (!current || widget.onActivate == null || executing) return;
    DescribedAction.cancelDescriptions();
    // Semantic activation and emergency actions must stay synchronous.
    if (widget.immediate || MediaQuery.accessibleNavigationOf(context)) {
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
    timer?.cancel();
    final ticket = ++generation;
    if (widget.retapWindowAfterDescription) {
      unawaited(describe(ticket, armAfterSpeech: true));
    } else {
      timer = Timer(const Duration(milliseconds: 500), () {
        if (identical(armed, this)) armed = null;
      });
      unawaited(describe(ticket));
    }
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
