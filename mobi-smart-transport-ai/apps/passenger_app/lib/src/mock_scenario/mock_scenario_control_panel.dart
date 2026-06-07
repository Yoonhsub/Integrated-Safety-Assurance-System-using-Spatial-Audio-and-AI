import 'package:flutter/material.dart';

import 'mock_scenario_controller.dart';

class MockScenarioControlPanel extends StatelessWidget {
  const MockScenarioControlPanel({super.key, required this.controller});

  final MockScenarioController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: '시연 시나리오 선택 및 재생 패널',
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.movie_filter_outlined, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '시나리오 재생',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Text(
                    '${state.elapsedLabel} / ${state.totalDurationLabel}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: state.scenarioId,
                decoration: const InputDecoration(
                  labelText: '데모 시나리오',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final scenario in controller.scenarios)
                    DropdownMenuItem<String>(
                      value: scenario.id,
                      child: Text(
                        scenario.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: state.isPlaying
                    ? null
                    : (value) {
                        if (value == null) return;
                        controller.selectScenario(value);
                      },
              ),
              const SizedBox(height: 10),
              Text(
                state.scenarioSummary,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: state.progress,
                  minHeight: 8,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: controller.togglePlayPause,
                    icon: Icon(
                      state.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    label: Text(state.isPlaying ? '일시정지' : '재생'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.restart,
                    icon: const Icon(Icons.replay),
                    label: const Text('처음부터'),
                  ),
                  IconButton.outlined(
                    tooltip: '이전 시나리오',
                    onPressed:
                        state.isPlaying ? null : controller.previousScenario,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.outlined(
                    tooltip: '다음 시나리오',
                    onPressed: state.isPlaying ? null : controller.nextScenario,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment<double>(
                    value: 0.75,
                    label: Text('0.75x'),
                    icon: Icon(Icons.slow_motion_video),
                  ),
                  ButtonSegment<double>(
                    value: 1.0,
                    label: Text('1x'),
                    icon: Icon(Icons.speed),
                  ),
                  ButtonSegment<double>(
                    value: 1.5,
                    label: Text('1.5x'),
                    icon: Icon(Icons.fast_forward),
                  ),
                ],
                selected: {state.playbackSpeed},
                onSelectionChanged: (selection) {
                  controller.setPlaybackSpeed(selection.first);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
