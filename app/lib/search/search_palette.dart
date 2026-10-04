import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'search_index.dart';

/// The shortcut as it reads on this platform.
String searchShortcutLabel() => Platform.isMacOS ? '⌘K' : 'Ctrl K';

/// Opens the search palette over the current screen. Resolves to the result
/// that was opened, or null when it was dismissed.
Future<SearchTarget?> showSearchPalette(BuildContext context, {required List<String> pageKeys}) {
  return showGeneralDialog<SearchTarget>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'search',
    barrierColor: Colors.black.withValues(alpha: BeacleColors.isDark ? 0.5 : 0.18),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, __, ___) => _SearchPalette(pageKeys: pageKeys),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(anim), child: child),
    ),
  );
}

class _SearchPalette extends StatefulWidget {
  final List<String> pageKeys;
  const _SearchPalette({required this.pageKeys});

  @override
  State<_SearchPalette> createState() => _SearchPaletteState();
}

class _SearchPaletteState extends State<_SearchPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  int _selected = 0;
  List<SearchHit> _hits = const [];

  static const _rowHeight = 48.0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int by) {
    if (_hits.isEmpty) return;
    setState(() => _selected = (_selected + by).clamp(0, _hits.length - 1));
    // Keep the highlighted row in view while arrowing through a long list.
    if (_scroll.hasClients) {
      final top = _selected * _rowHeight;
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top);
      } else if (top + _rowHeight > _scroll.offset + view) {
        _scroll.jumpTo(top + _rowHeight - view);
      }
    }
  }

  void _open([int? i]) {
    final index = i ?? _selected;
    if (index < 0 || index >= _hits.length) return;
    Navigator.of(context).pop(_hits[index].target);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l = context.l;
    _hits = searchAll(
      l: l,
      query: _query.text,
      servers: state.vpsList,
      snapshots: state.snapshots,
      alerts: state.alerts,
      pageKeys: widget.pageKeys,
      darkTheme: BeacleColors.isDark,
    );
    if (_selected >= _hits.length) _selected = _hits.isEmpty ? 0 : _hits.length - 1;

    // Pinned near the top rather than centred, so the field stays put while
    // the list under it grows and shrinks with each keystroke.
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
        child: Material(
          color: BeacleColors.card,
          elevation: 0,
          borderRadius: BorderRadius.circular(BeacleRadius.dialog),
          child: Container(
            width: 640,
            constraints: const BoxConstraints(maxHeight: 520),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(BeacleRadius.dialog),
              border: Border.all(color: BeacleColors.cardBorder),
              boxShadow: [BoxShadow(color: BeacleColors.shadow, blurRadius: 32, offset: const Offset(0, 12))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                    const SingleActivator(LogicalKeyboardKey.pageDown): () => _move(8),
                    const SingleActivator(LogicalKeyboardKey.pageUp): () => _move(-8),
                    const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
                  },
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: l.t('srchHint'),
                      prefixIcon: Icon(Icons.search, size: 20, color: BeacleColors.textDim),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    ),
                    onChanged: (_) => setState(() {
                      _selected = 0;
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    }),
                    onSubmitted: (_) => _open(),
                  ),
                ),
                Divider(height: 1, color: BeacleColors.border),
                Flexible(
                  child: _hits.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Text(l.f('srchNothing', {'q': _query.text.trim()}),
                              style: TextStyle(fontSize: 13, color: BeacleColors.textDim)),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          itemExtent: _rowHeight,
                          itemCount: _hits.length,
                          itemBuilder: (_, i) => _HitRow(
                            hit: _hits[i],
                            selected: i == _selected,
                            onHover: () {
                              if (_selected != i) setState(() => _selected = i);
                            },
                            onTap: () => _open(i),
                          ),
                        ),
                ),
                Divider(height: 1, color: BeacleColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  child: Row(children: [
                    _Key('↑↓'),
                    const SizedBox(width: 6),
                    Text(l.t('srchMove'), style: _footStyle),
                    const SizedBox(width: 16),
                    _Key('Enter'),
                    const SizedBox(width: 6),
                    Text(l.t('srchOpen'), style: _footStyle),
                    const SizedBox(width: 16),
                    _Key('Esc'),
                    const SizedBox(width: 6),
                    Text(l.t('close'), style: _footStyle),
                    const Spacer(),
                    Text(l.f('srchCount', {'n': _hits.length}), style: _footStyle),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle get _footStyle => TextStyle(fontSize: 11, color: BeacleColors.textDim);
}

IconData _iconFor(SearchHit h) => switch (h.kind) {
      SearchKind.page => Icons.space_dashboard_outlined,
      SearchKind.action => switch (h.target.action) {
          SearchAction.addVps => Icons.add_circle_outline,
          SearchAction.ssh => Icons.terminal,
          SearchAction.lightTheme => Icons.light_mode_outlined,
          SearchAction.darkTheme => Icons.dark_mode_outlined,
          null => Icons.bolt,
        },
      SearchKind.server => Icons.dns_outlined,
      SearchKind.container => Icons.view_in_ar_outlined,
      SearchKind.service => Icons.miscellaneous_services_outlined,
      SearchKind.screen => Icons.terminal,
      SearchKind.site => Icons.language,
      SearchKind.alert => Icons.warning_amber_rounded,
    };

String _kindLabel(L l, SearchKind k) => l.t(switch (k) {
      SearchKind.page => 'srchPage',
      SearchKind.action => 'srchAction',
      SearchKind.server => 'srchServer',
      SearchKind.container => 'srchContainer',
      SearchKind.service => 'srchService',
      SearchKind.screen => 'srchScreen',
      SearchKind.site => 'srchSite',
      SearchKind.alert => 'srchAlert',
    });

class _HitRow extends StatelessWidget {
  final SearchHit hit;
  final bool selected;
  final VoidCallback onHover, onTap;
  const _HitRow({required this.hit, required this.selected, required this.onHover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(BeacleColors.text.withValues(alpha: 0.07), BeacleColors.card) : Colors.transparent,
            borderRadius: BorderRadius.circular(BeacleRadius.control),
          ),
          child: Row(
            children: [
              Icon(_iconFor(hit), size: 17, color: hit.kind == SearchKind.alert ? BeacleColors.warn : BeacleColors.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: BeacleColors.text)),
                    if (hit.subtitle.isNotEmpty)
                      Text(hit.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(_kindLabel(l, hit.kind), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              if (selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.keyboard_return, size: 14, color: BeacleColors.textDim),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A keyboard key, drawn as a small cap.
class _Key extends StatelessWidget {
  final String label;
  const _Key(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: BeacleColors.textDim, fontWeight: FontWeight.w600)),
    );
  }
}

/// The magnifier in the top bar: reads as a search field, opens the palette.
class SearchButton extends StatefulWidget {
  final VoidCallback onTap;
  const SearchButton({super.key, required this.onTap});

  @override
  State<SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends State<SearchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Tooltip(
      message: l.f('srchTooltip', {'key': searchShortcutLabel()}),
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: LayoutBuilder(builder: (context, c) {
            // A field where there is room for one, the bare magnifier where
            // the top bar is tight.
            final compact = c.maxWidth < 150;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 32,
              padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
              decoration: BoxDecoration(
                color: _hover ? BeacleColors.surfaceHi : BeacleColors.card,
                borderRadius: BorderRadius.circular(BeacleRadius.control),
                border: Border.all(color: _hover ? BeacleColors.borderGlow : BeacleColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.search, size: 16, color: BeacleColors.textDim),
                  if (!compact) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l.t('srchButton'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                    ),
                    const SizedBox(width: 8),
                    _Key(searchShortcutLabel()),
                  ],
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
