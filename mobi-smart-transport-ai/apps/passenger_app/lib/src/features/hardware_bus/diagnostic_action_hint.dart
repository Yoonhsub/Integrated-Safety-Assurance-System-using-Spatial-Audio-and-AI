import 'package:flutter/material.dart';

/// Adds a screen-reader hint without changing a diagnostic control's action.
class DiagnosticActionHint extends StatelessWidget {
  const DiagnosticActionHint(
      {super.key, required this.hint, required this.child});

  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      MergeSemantics(child: Semantics(hint: hint, child: child));
}
