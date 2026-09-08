import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// What a server was running when a metric jumped.
///
/// This is the answer to the question the chart provokes and could not settle:
/// the CPU was at the ceiling at four in the morning, and by the time anyone
/// looks, the process responsible has long exited. The agent writes the list
/// down at the moment it can still see it; this shows what it wrote.
class SpikeDialog extends StatelessWidget {
  final SpikeRecord spike;
  const SpikeDialog({super.key, required this.spike});

  bool get _isMem => spike.metric == 'mem';
  String get _metricLabel => _isMem ? 'Memory' : 'CPU';

  @override
  Widget build(BuildContext context) {
    final at = spike.at.toLocal();
    return Dialog(
      backgroundColor: BeacleColors.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, size: 18, color: BeacleColors.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$_metricLabel spike · ${_fmtTime(at)}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // The baseline is the whole reason this was recorded, so it is
              // said out loud: 30% means nothing until you know the machine
              // normally sits at 8%.
              Text(
                '${spike.value.toStringAsFixed(0)}%, against a usual '
                '${spike.baseline.toStringAsFixed(0)}% for this server.',
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
              const SizedBox(height: 14),

              if (spike.top.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No process list was captured for this one.',
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                  ),
                )
              else ...[
                Text(
                  'Running at the time, busiest first:',
                  style: TextStyle(
                      fontSize: 11,
                      color: BeacleColors.textDim,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SmoothListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in spike.top) _ProcessRow(proc: p, rankByMem: _isMem),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),
              const Text(
                'A snapshot from that minute — these processes may be long gone.',
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (sameDay) return 'today $hm';
    final yesterday = now.subtract(const Duration(days: 1));
    if (t.year == yesterday.year && t.month == yesterday.month && t.day == yesterday.day) {
      return 'yesterday $hm';
    }
    return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} $hm';
  }
}

class _ProcessRow extends StatelessWidget {
  final SpikeProcess proc;

  /// Which number to lead with. A memory spike explained by a CPU column
  /// invites the reader to blame the wrong process.
  final bool rankByMem;
  const _ProcessRow({required this.proc, required this.rankByMem});

  @override
  Widget build(BuildContext context) {
    final lead = rankByMem ? proc.mem : proc.cpu;
    final other = rankByMem ? proc.cpu : proc.mem;
    final otherLabel = rankByMem ? 'cpu' : 'mem';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              '${lead.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'Consolas',
                fontWeight: FontWeight.w600,
                color: lead >= 50 ? BeacleColors.warn : BeacleColors.text,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(proc.name,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Text('pid ${proc.pid}',
                        style: const TextStyle(
                            fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim)),
                    if (proc.user.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(proc.user,
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                    ],
                    const SizedBox(width: 8),
                    Text('$otherLabel ${other.toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ],
                ),
                if (proc.command.isNotEmpty)
                  // Clickable because the command line is what you paste into
                  // a terminal next, and it is usually too long to retype.
                  Tooltip(
                    message: 'Click to copy · ${proc.command}',
                    waitDuration: const Duration(milliseconds: 600),
                    child: InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: proc.command));
                        showToast(context, 'Copied');
                      },
                      child: Text(
                        proc.command,
                        style: const TextStyle(
                            fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
