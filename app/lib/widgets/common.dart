import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class PanelCard extends StatelessWidget {
  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;
  const PanelCard({super.key, required this.child, this.title, this.trailing, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BeacleColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(children: [
              Expanded(
                child: Text(title!,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: BeacleColors.textDim, letterSpacing: 0.4)),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

/// Glass-style elevated card (Linear / Vercel aesthetic).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double? width;
  final BorderRadius? borderRadius;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.width,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: BeacleColors.glass,
        borderRadius: borderRadius ?? BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(color: BeacleColors.glow.withValues(alpha: 0.03), blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class StatusDot extends StatelessWidget {
  final String status;
  final double size;
  const StatusDot(this.status, {super.key, this.size = 9});

  @override
  Widget build(BuildContext context) {
    final color = BeacleColors.statusColor(status);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)],
      ),
    );
  }
}

class MetricBar extends StatelessWidget {
  final String label;
  final double percent; // 0..100
  final String? detail;
  const MetricBar({super.key, required this.label, required this.percent, this.detail});

  Color get _color {
    if (percent >= 90) return BeacleColors.err;
    if (percent >= 75) return BeacleColors.warn;
    return BeacleColors.textDim;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
            const Spacer(),
            Text(detail ?? '${percent.toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (percent / 100).clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: BeacleColors.surfaceHi,
            valueColor: AlwaysStoppedAnimation(_color),
          ),
        ),
      ],
    );
  }
}

/// Row that gets the standard white-grey hover highlight.
class HoverRow extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  const HoverRow({super.key, required this.child, this.onTap, this.selected = false});

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: widget.selected
                ? BeacleColors.surfaceHi
                : _hover
                    ? BeacleColors.hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class SmallButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  const SmallButton(this.label, {super.key, this.icon, this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, size: 14, color: color ?? BeacleColors.text) : const SizedBox.shrink(),
      label: Text(label, style: TextStyle(fontSize: 12, color: color ?? BeacleColors.text)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: BeacleColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class CopyField extends StatelessWidget {
  final String value;
  const CopyField(this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: BeacleColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: BeacleColors.ok)),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 14, color: BeacleColors.textDim),
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
                width: 220,
                behavior: SnackBarBehavior.floating,
              ));
            },
          ),
        ],
      ),
    );
  }
}

/// Simple monospace log viewer dialog.
Future<void> showLogsDialog(BuildContext context, String title, Future<String> Function() loader) async {
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: Container(
        width: 900,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(ctx)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<String>(
                future: loader(),
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}', style: const TextStyle(color: BeacleColors.err)));
                  }
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: BeacleColors.bg, borderRadius: BorderRadius.circular(6)),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        snap.data!.isEmpty ? '(no output)' : snap.data!,
                        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.4),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void showToast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? BeacleColors.err : BeacleColors.surfaceHi,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 3),
  ));
}
