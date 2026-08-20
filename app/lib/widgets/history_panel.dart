import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'metric_chart.dart';

/// Recorded history for one server: CPU, memory and network over time.
///
/// The point of it is looking backwards. Live numbers already sit above this
/// panel; what they cannot answer is whether the box was thrashing at four in
/// the morning, or when exactly it fell off the network. So the range buttons
/// and the drag-to-scroll are the feature, not decoration.
class HistoryPanel extends StatefulWidget {
  final Vps vps;
  const HistoryPanel({super.key, required this.vps});

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  static const _ranges = <String, Duration>{
    '1h': Duration(hours: 1),
    '6h': Duration(hours: 6),
    '24h': Duration(hours: 24),
    '7d': Duration(days: 7),
  };

  String _range = '24h';
  late DateTime _from;
  late DateTime _to;

  MetricHistory? _history;
  bool _loading = true;
  String? _error;

  /// Whether the window follows the present. On by default; scrolling or
  /// zooming the chart turns it off, exactly the way scrolling up in a log
  /// viewer stops it auto-scrolling. Nothing is more irritating than a chart
  /// that yanks itself back to now while you are reading last night.
  bool _sync = true;

  Timer? _refresh;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _to = DateTime.now();
    _from = _to.subtract(_ranges[_range]!);
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_sync) _slideToNow();
    });
  }

  @override
  void didUpdateWidget(HistoryPanel old) {
    super.didUpdateWidget(old);
    if (old.vps.id != widget.vps.id) {
      _sync = true;
      _to = DateTime.now();
      _from = _to.subtract(_ranges[_range] ?? const Duration(hours: 24));
      _load();
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _slideToNow() {
    final span = _to.difference(_from);
    setState(() {
      _to = DateTime.now();
      _from = _to.subtract(span);
    });
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final id = widget.vps.id;
    try {
      // Fetch a little either side of the window so a small drag has data to
      // show before the next request lands.
      final pad = _to.difference(_from) ~/ 4;
      final h = await state.api.vpsHistory(
        id,
        from: _from.subtract(pad),
        to: _to.add(pad),
      );
      if (!mounted || widget.vps.id != id) return;
      setState(() {
        _history = h;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || widget.vps.id != id) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _onWindowChanged(DateTime from, DateTime to) {
    setState(() {
      _from = from;
      _to = to;
      // Touching the chart at all is a statement of intent: the reader is
      // driving now, so following stops until they ask for it back. Zooming
      // while parked at the present counts too — otherwise the window would
      // resize under them on the next tick.
      _sync = false;
    });
    // Panning fires continuously; refetch once the hand stops rather than on
    // every frame.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  void _selectRange(String key) {
    final span = _ranges[key];
    if (span == null) return;
    setState(() {
      _range = key;
      _to = DateTime.now();
      _from = _to.subtract(span);
      // Picking a range means "show me the last N hours", which is a request
      // to be at the present — so it turns following back on.
      _sync = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final h = _history;
    final samples = h?.samples ?? const <MetricSample>[];

    return PanelCard(
      title: 'HISTORY',
      trailing: Row(
        children: [
          // Same control as the log viewer's Follow/Paused, for the same
          // reason and with the same wording, so it reads as one idea.
          Tooltip(
            message: _sync
                ? 'Following live data'
                : 'Scrolled back — click to return to now',
            child: SmallButton(
              _sync ? 'Sync' : 'Paused',
              icon: _sync ? Icons.sync : Icons.pause,
              color: _sync ? BeacleColors.ok : BeacleColors.textDim,
              onPressed: () {
                if (_sync) {
                  setState(() => _sync = false);
                } else {
                  setState(() => _sync = true);
                  _slideToNow();
                }
              },
            ),
          ),
          const SizedBox(width: 10),
          for (final key in _ranges.keys) ...[
            _RangeChip(
              label: key,
              // A preset stops being "the" range the moment you scroll away
              // from now, so it stops looking selected too.
              selected: _range == key && _sync,
              onTap: () => _selectRange(key),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _sync
                ? 'Following live data — drag to scroll back in time, Ctrl+scroll to zoom, '
                    'hover for exact values.'
                : 'Showing ${_fmtRange(_from, _to)} — drag to scroll, Ctrl+scroll to zoom, '
                    'press Paused to return to live.',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(height: 14),

          if (_loading && samples.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('History unavailable: $_error',
                  style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
            )
          else if (samples.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Text(
                'Nothing recorded for this window yet. The backend keeps one sample a '
                'minute, so a chart worth reading appears within the hour.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
              ),
            )
          else ...[
            MetricChart(
              title: 'CPU',
              samples: samples,
              from: _from,
              to: _to,
              maxY: 100,
              boundsFirst: h?.first,
              boundsLast: h?.last,
              onWindowChanged: _onWindowChanged,
              series: [
                ChartSeries(
                  label: 'CPU',
                  color: ChartColors.cpu,
                  value: (s) => s.cpu,
                  format: (v) => '${v.toStringAsFixed(0)}%',
                ),
              ],
            ),
            const SizedBox(height: 18),
            MetricChart(
              title: 'MEMORY',
              samples: samples,
              from: _from,
              to: _to,
              maxY: 100,
              boundsFirst: h?.first,
              boundsLast: h?.last,
              onWindowChanged: _onWindowChanged,
              series: [
                ChartSeries(
                  label: 'RAM',
                  color: ChartColors.ram,
                  value: (s) => s.mem,
                  format: (v) => '${v.toStringAsFixed(0)}%',
                ),
              ],
            ),
            const SizedBox(height: 18),
            MetricChart(
              title: 'NETWORK',
              samples: samples,
              from: _from,
              to: _to,
              boundsFirst: h?.first,
              boundsLast: h?.last,
              onWindowChanged: _onWindowChanged,
              series: [
                ChartSeries(
                  label: 'in',
                  color: ChartColors.netIn,
                  value: (s) => s.rxPerS.toDouble(),
                  format: (v) => '${fmtBytes(v)}/s',
                ),
                ChartSeries(
                  label: 'out',
                  color: ChartColors.netOut,
                  value: (s) => s.txPerS.toDouble(),
                  format: (v) => '${fmtBytes(v)}/s',
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Row(
              children: [
                _OutageKey(),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'A shaded band is a stretch with no samples — the agent was not '
                    'reporting, so the server was unreachable or down.',
                    style: TextStyle(fontSize: 10, color: BeacleColors.textDim, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _fmtRange(DateTime from, DateTime to) {
    String at(DateTime t) {
      final l = t.toLocal();
      return '${l.day}/${l.month} ${l.hour.toString().padLeft(2, '0')}:'
          '${l.minute.toString().padLeft(2, '0')}';
    }

    return '${at(from)} → ${at(to)}';
  }
}

class _OutageKey extends StatelessWidget {
  const _OutageKey();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 12,
      decoration: BoxDecoration(
        color: BeacleColors.err.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: BeacleColors.err.withValues(alpha: 0.3)),
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RangeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? BeacleColors.surfaceHi : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: selected ? BeacleColors.borderGlow : BeacleColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? BeacleColors.text : BeacleColors.textDim,
          ),
        ),
      ),
    );
  }
}
