import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voicegpt/core/models/owner_voiceprint_sample.dart';
import 'package:voicegpt/core/notifiers/speech_notifier_simplified.dart';

/// 右上角声纹库：紧凑布局，1–3 条音频。
class OwnerVoiceprintLibraryPanel extends StatelessWidget {
  const OwnerVoiceprintLibraryPanel({
    super.key,
    required this.speech,
  });

  final SpeechNotifierSimplified speech;

  @override
  Widget build(BuildContext context) {
    final samples = speech.ownerVoiceprintSamples;
    final selectedId = speech.ownerVoiceprintSelectedId;
    final playingId = speech.ownerVoiceprintPlayingId;
    final enrolling = speech.isOwnerVoiceprintEnrolling;
    final maxH = MediaQuery.sizeOf(context).height * 0.38;
    final panelW =
        (MediaQuery.sizeOf(context).width * 0.42).clamp(200.0, 248.0);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: panelW,
        constraints: BoxConstraints(maxHeight: maxH),
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.library_music,
                    color: Colors.lightGreenAccent, size: 16),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    '声纹库(≤3)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _MiniIconBtn(
                  icon: Icons.add,
                  color: Colors.lightGreenAccent,
                  enabled: speech.canAddOwnerVoiceprintSample && !enrolling,
                  tooltip: '新录音',
                  onTap: () {
                    unawaited(
                        speech.startOwnerVoiceprintEnrollmentFromLibrary());
                  },
                ),
                _MiniIconBtn(
                  icon: Icons.remove,
                  color: Colors.redAccent,
                  enabled: speech.canDeleteOwnerVoiceprintSample && !enrolling,
                  tooltip: '删除选中',
                  onTap: () {
                    unawaited(speech.deleteSelectedOwnerVoiceprintSample());
                  },
                ),
                _MiniIconBtn(
                  icon: Icons.close,
                  color: Colors.white70,
                  enabled: true,
                  tooltip: '关闭',
                  onTap: speech.closeOwnerVoiceprintLibrary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              SpeechNotifierSimplified.ownerVoiceprintEnrollmentPrompt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 10,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH - 72),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (samples.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '暂无，点 ＋ 录音',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.65),
                            fontSize: 11,
                          ),
                        ),
                      )
                    else
                      ...samples.map(
                        (s) => _SampleTile(
                          sample: s,
                          selected: s.id == selectedId,
                          playing: s.id == playingId,
                          onSelect: () {
                            unawaited(speech.selectOwnerVoiceprintSample(s.id));
                          },
                          onPlay: s.hasAudio
                              ? () {
                                  unawaited(
                                      speech.playOwnerVoiceprintSample(s.id));
                                }
                              : null,
                        ),
                      ),
                    if (enrolling) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        minHeight: 3,
                        value: (speech.ownerVoiceprintCaptureMs / 10000)
                            .clamp(0.0, 1.0),
                        backgroundColor: Colors.white12,
                        color: Colors.orangeAccent,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        speech.ownerVoiceprintEnrollmentHint,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniIconBtn extends StatelessWidget {
  const _MiniIconBtn({
    required this.icon,
    required this.color,
    required this.enabled,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final bool enabled;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 18,
            color: enabled ? color : Colors.white30,
          ),
        ),
      ),
    );
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({
    required this.sample,
    required this.selected,
    required this.playing,
    required this.onSelect,
    this.onPlay,
  });

  final OwnerVoiceprintSample sample;
  final bool selected;
  final bool playing;
  final VoidCallback onSelect;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? Colors.teal.withOpacity(0.22) : Colors.white10,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            onSelect();
            onPlay?.call();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? Colors.tealAccent : Colors.white54,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sample.label,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      Text(
                        sample.isActive
                            ? '${sample.durationLabel}·当前'
                            : sample.durationLabel,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
                if (sample.hasAudio)
                  InkWell(
                    onTap: onPlay,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        playing ? Icons.volume_up : Icons.play_arrow_rounded,
                        color: playing ? Colors.amberAccent : Colors.white70,
                        size: 18,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.music_off, color: Colors.white30, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
