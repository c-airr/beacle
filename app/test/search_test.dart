import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/l10n/language.dart';
import 'package:beacle/l10n/strings.dart';
import 'package:beacle/models/models.dart';
import 'package:beacle/search/search_index.dart';

void main() {
  group('matchScore', () {
    test('needs every word somewhere', () {
      expect(matchScore('web prod', ['web-1', 'prod']), isNotNull);
      expect(matchScore('web staging', ['web-1', 'prod']), isNull);
    });

    test('a prefix of the name beats a word inside it, which beats the middle', () {
      final prefix = matchScore('ngi', ['nginx'])!;
      final word = matchScore('ngi', ['my-nginx'])!;
      final middle = matchScore('ngi', ['xnginx'])!;
      expect(prefix, greaterThan(word));
      expect(word, greaterThan(middle));
    });

    test('the name counts more than the other fields', () {
      expect(matchScore('redis', ['redis', 'cache']), greaterThan(matchScore('redis', ['cache', 'redis:7'])!));
    });

    test('letters in order still match, below a real hit', () {
      final fuzzy = matchScore('ngx', ['nginx']);
      expect(fuzzy, isNotNull);
      expect(fuzzy, lessThan(matchScore('nginx', ['nginx'])!));
    });

    test('is case-insensitive', () => expect(matchScore('WEB', ['web-1']), isNotNull));
  });

  group('searchAll', () {
    final l = const L(AppLanguage.en);
    final web = Vps.fromJson({'id': 'v1', 'name': 'web-1', 'host': '100.64.0.1', 'tags': ['prod']});
    final db = Vps.fromJson({'id': 'v2', 'name': 'db-1', 'host': '100.64.0.2'});
    final snaps = {
      'v1': VpsSnapshot.fromJson({
        'docker': {
          'available': true,
          'containers': [
            {'id': 'c1', 'name': 'nginx', 'image': 'nginx:1.27', 'state': 'running'},
            {'id': 'c2', 'name': 'app', 'image': 'ghcr.io/me/app', 'state': 'running'},
          ],
        },
        'services': {
          'systemd': [
            {'name': 'nginx.service', 'description': 'A high performance web server'},
          ],
          'screen': [
            {'name': 'bot', 'command': 'python3 bot.py', 'running': true},
          ],
        },
        'proxy': {
          'provider': 'caddy',
          'sites': [
            {'id': 's1', 'domain': 'shop.example.com', 'upstream': '127.0.0.1:3000'},
          ],
        },
      }),
    };

    List<SearchHit> search(String q) => searchAll(
          l: l,
          query: q,
          servers: [web, db],
          snapshots: snaps,
          alerts: const [],
          pageKeys: const ['navOverview', 'navDocker', 'navSsh'],
          darkTheme: true,
        );

    test('an empty query lists pages, actions and servers, not every container', () {
      final kinds = search('').map((h) => h.kind).toSet();
      expect(kinds, containsAll([SearchKind.page, SearchKind.action, SearchKind.server]));
      expect(kinds, isNot(contains(SearchKind.container)));
    });

    test('finds a container by image and opens it on its server', () {
      final hit = search('ghcr').first;
      expect(hit.kind, SearchKind.container);
      expect(hit.title, 'app');
      expect(hit.target.vpsId, 'v1');
      expect(hit.target.query, 'app');
    });

    test('finds a server by tag', () {
      expect(search('prod').first.target.vpsId, 'v1');
    });

    test('finds a systemd unit without its .service suffix, and a proxy site', () {
      final nginx = search('nginx');
      expect(nginx.map((h) => h.kind), containsAll([SearchKind.container, SearchKind.service]));
      expect(search('shop').first.kind, SearchKind.site);
    });

    test('finds pages in the interface language', () {
      final pl = searchAll(
        l: const L(AppLanguage.pl),
        query: 'przeg',
        servers: const [],
        snapshots: const {},
        alerts: const [],
        pageKeys: const ['navOverview'],
        darkTheme: true,
      );
      expect(pl.single.kind, SearchKind.page);
      expect(pl.single.title, 'Przegląd');
    });

    test('pages answer to their English name in any language', () {
      final pl = searchAll(
        l: const L(AppLanguage.pl),
        query: 'settings',
        servers: const [],
        snapshots: const {},
        alerts: const [],
        pageKeys: const ['navOverview', 'navSettings'],
        darkTheme: true,
      );
      expect(pl.first.title, 'Ustawienia');
    });

    test('does not match on internal keys', () {
      expect(search('nav'), isEmpty);
    });

    test('offers the other theme', () {
      expect(search('light').any((h) => h.target.action == SearchAction.lightTheme), isTrue);
      expect(search('dark').any((h) => h.target.action == SearchAction.darkTheme), isFalse);
    });
  });
}
