import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/api/api_client.dart';
import 'package:beacle/models/models.dart';
import 'package:beacle/screens/files_screen.dart';
import 'package:beacle/state/app_state.dart';

/// A server's filesystem as fs/dir would answer it. '' is the home folder.
class _FakeApi extends ApiClient {
  _FakeApi() : super('');

  static const _fs = {
    '/': ['root/', 'etc/', 'swapfile'],
    '/root': ['projects/', '.bashrc'],
    '/root/projects': <String>[],
    '/etc': ['nginx/', 'hosts'],
    '/etc/nginx': ['nginx.conf'],
  };

  @override
  Future<FsListing> fsDir(String vpsId, String path, {bool hidden = false}) async {
    final p = path.isEmpty ? '/root' : path;
    final names = _fs[p];
    if (names == null) throw ApiException('no such folder', 404, {'error': 'not found'});
    return FsListing.fromJson({
      'path': p,
      'entries': [
        for (final n in names)
          {
            'name': n.replaceAll('/', ''),
            'path': '${p == '/' ? '' : p}/${n.replaceAll('/', '')}',
            'is_dir': n.endsWith('/'),
          }
      ],
    });
  }
}

class _State extends AppState {
  final _api = _FakeApi();

  @override
  ApiClient get api => _api;
}

void main() {
  testWidgets('the tree opens the way to the current folder and expands on demand', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _State();
    state.vpsList = [
      Vps.fromJson({'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'})
    ];
    state.snapshots['a'] = VpsSnapshot.fromJson(const {});
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: FilesScreen())),
    ));
    await tester.pumpAndSettle();

    // Home is /root: the tree shows / with root open, and root's folder
    // twice — in the tree and in the list on the right.
    expect(find.text('/'), findsWidgets);
    expect(find.text('etc'), findsOneWidget);
    expect(find.text('projects'), findsNWidgets(2));
    expect(find.text('nginx'), findsNothing, reason: 'etc is closed');
    expect(find.text('swapfile'), findsNothing, reason: 'the tree shows folders only');

    // The arrow beside etc opens it without leaving /root.
    final etcRow = find.ancestor(of: find.text('etc'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: etcRow, matching: find.byIcon(Icons.chevron_right)));
    await tester.pumpAndSettle();
    expect(find.text('nginx'), findsOneWidget);
    expect(find.text('.bashrc'), findsOneWidget, reason: 'the list still shows /root');

    // Clicking a folder's name opens it on the right.
    await tester.tap(find.text('nginx'));
    await tester.pumpAndSettle();
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('.bashrc'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });
}
