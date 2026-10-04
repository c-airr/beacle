import '../l10n/alert_text.dart';
import '../l10n/language.dart';
import '../l10n/strings.dart';
import '../models/models.dart';

/// What a search result is, which decides its icon, its label and where
/// opening it goes.
enum SearchKind { page, action, server, container, service, screen, site, alert }

/// Where opening a result takes you. The shell turns this into navigation;
/// keeping it as data lets the ranking be tested without a widget tree.
class SearchTarget {
  final SearchKind kind;

  /// Sidebar tab for [SearchKind.page]: an index into the main items, then
  /// the tools (see AppShellState.items / toolItems).
  final int tab;

  /// The server the result lives on, if any.
  final String? vpsId;

  /// What to put in the destination's filter field.
  final String query;

  /// For [SearchKind.action]: which one.
  final SearchAction? action;

  const SearchTarget(this.kind, {this.tab = -1, this.vpsId, this.query = '', this.action});
}

enum SearchAction { addVps, ssh, lightTheme, darkTheme }

class SearchHit {
  final SearchTarget target;
  final String title, subtitle;
  final int score;
  const SearchHit(this.target, this.title, this.subtitle, this.score);

  SearchKind get kind => target.kind;
}

/// One thing the palette can find: the text it is found by (the first field
/// counts most) and where it leads.
class _Entry {
  final SearchTarget target;
  final String title, subtitle;
  final List<String> fields;
  const _Entry(this.target, this.title, this.subtitle, this.fields);
}

/// How well [query] matches [fields]; null when it does not. Every word of
/// the query has to be found somewhere. A word at the start of the main
/// field beats one at the start of a word inside it, which beats one in the
/// middle; matches in the other fields (host, image, description) count
/// less. A query whose letters appear in order in the main field ("ngx" for
/// "nginx") still matches, just below everything else.
int? matchScore(String query, List<String> fields) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return 0;
  final hay = [for (final f in fields) f.toLowerCase()];
  var total = 0;
  for (final w in words) {
    var best = 0;
    for (var i = 0; i < hay.length; i++) {
      final h = hay[i];
      final at = h.indexOf(w);
      if (at < 0) continue;
      final atWordStart = at == 0 || !RegExp(r'[a-z0-9]').hasMatch(h[at - 1]);
      final s = i == 0
          ? (at == 0 ? (h.length == w.length ? 120 : 100) : (atWordStart ? 80 : 60))
          : (atWordStart ? 40 : 25);
      if (s > best) best = s;
    }
    if (best == 0 && words.length == 1 && w.length >= 2 && hay.isNotEmpty && _inOrder(w, hay.first)) {
      best = 10;
    }
    if (best == 0) return null;
    total += best;
  }
  return total;
}

bool _inOrder(String needle, String hay) {
  var i = 0;
  for (final c in hay.split('')) {
    if (i < needle.length && c == needle[i]) i++;
  }
  return i == needle.length;
}

/// The search palette's results for [query], best first. With an empty query
/// it lists the pages, the quick actions and the servers, so the palette is
/// also a keyboard way around the app.
List<SearchHit> searchAll({
  required L l,
  required String query,
  required List<Vps> servers,
  required Map<String, VpsSnapshot> snapshots,
  required List<Alert> alerts,
  required List<String> pageKeys,
  required bool darkTheme,
  int limit = 40,
}) {
  final entries = <_Entry>[];

  // Pages answer to their English name too, so "docker" or "settings" works
  // whatever the interface language.
  const en = L(AppLanguage.en);
  for (var i = 0; i < pageKeys.length; i++) {
    final name = l.t(pageKeys[i]);
    entries.add(_Entry(SearchTarget(SearchKind.page, tab: i), name, '', [name, en.t(pageKeys[i])]));
  }

  final addVps = l.t('addVps');
  entries.add(_Entry(const SearchTarget(SearchKind.action, action: SearchAction.addVps), addVps, '',
      [addVps, 'add server new vps']));
  final themeTitle = l.t(darkTheme ? 'srchLightTheme' : 'srchDarkTheme');
  entries.add(_Entry(
    SearchTarget(SearchKind.action, action: darkTheme ? SearchAction.lightTheme : SearchAction.darkTheme),
    themeTitle,
    '',
    [themeTitle, 'theme light dark'],
  ));

  final names = {for (final v in servers) v.id: v.name};
  for (final v in servers) {
    final where = [v.host, if (v.location.isNotEmpty) v.location].join(' · ');
    entries.add(_Entry(SearchTarget(SearchKind.server, vpsId: v.id), v.name, where,
        [v.name, v.host, v.publicIp, v.tailscaleName, v.location, ...v.tags]));
    final ssh = l.f('srchSshTo', {'name': v.name});
    entries.add(_Entry(SearchTarget(SearchKind.action, action: SearchAction.ssh, vpsId: v.id), ssh, v.host,
        [ssh, 'ssh terminal shell ${v.name}']));
  }

  for (final v in servers) {
    final snap = snapshots[v.id];
    if (snap == null) continue;
    for (final c in snap.docker.containers) {
      entries.add(_Entry(
        SearchTarget(SearchKind.container, vpsId: v.id, query: c.name),
        c.name,
        '${v.name} · ${c.image}',
        [c.name, c.image, c.composeProject, c.composeService],
      ));
    }
    for (final u in snap.services.systemd) {
      final unit = u.name.endsWith('.service') ? u.name.substring(0, u.name.length - 8) : u.name;
      entries.add(_Entry(
        SearchTarget(SearchKind.service, vpsId: v.id, query: u.name),
        u.name,
        [v.name, if (u.description.isNotEmpty) u.description].join(' · '),
        [unit, u.description],
      ));
    }
    for (final s in snap.services.screen) {
      entries.add(_Entry(
        SearchTarget(SearchKind.screen, vpsId: v.id, query: s.name),
        s.name,
        [v.name, if (s.running) s.command].join(' · '),
        [s.name, s.command],
      ));
    }
    for (final p in snap.proxy.sites) {
      entries.add(_Entry(
        SearchTarget(SearchKind.site, vpsId: v.id, query: p.domain),
        p.domain,
        [v.name, if (p.upstream.isNotEmpty) '→ ${p.upstream}'].join(' · '),
        [p.domain, p.upstream],
      ));
    }
  }

  for (final a in alerts.where((a) => !a.resolved)) {
    final msg = alertMessage(l, a);
    entries.add(_Entry(SearchTarget(SearchKind.alert, vpsId: a.vpsId), msg,
        names[a.vpsId] ?? a.vpsName, [msg, a.vpsName, alertTypeLabel(l, a.type), a.message]));
  }

  final q = query.trim();
  if (q.isEmpty) {
    return [
      for (final e in entries)
        if (e.target.kind == SearchKind.page ||
            e.target.kind == SearchKind.server ||
            (e.target.kind == SearchKind.action && e.target.action != SearchAction.ssh))
          SearchHit(e.target, e.title, e.subtitle, 0),
    ].take(limit).toList();
  }

  final hits = <SearchHit>[];
  for (final e in entries) {
    final s = matchScore(q, e.fields);
    if (s != null) hits.add(SearchHit(e.target, e.title, e.subtitle, s));
  }
  // Best match first; on a tie, the kinds you are most likely to mean.
  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.kind.index.compareTo(b.kind.index);
  });
  return hits.take(limit).toList();
}
