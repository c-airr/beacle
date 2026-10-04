import '../models/models.dart';
import 'strings.dart';

/// The backend writes alert messages in English (they also go out through
/// webhooks). The panel recognises its fixed templates and shows them in the
/// interface language; anything else — a proxy error, a newer backend's
/// wording — is shown as sent.
final _templates = <RegExp, String Function(L, RegExpMatch)>{
  RegExp(r'^CPU above (\d+)% for (\d+)s \(now (\d+)%\)$'): (l, m) =>
      l.f('alMsgCpu', {'limit': m[1], 's': m[2], 'now': m[3]}),
  RegExp(r'^RAM above (\d+)% for (\d+)s \(now (\d+)%\)$'): (l, m) =>
      l.f('alMsgRam', {'limit': m[1], 's': m[2], 'now': m[3]}),
  RegExp(r'^Disk (.+) at (\d+)%$'): (l, m) => l.f('alMsgDisk', {'mount': m[1], 'p': m[2]}),
  RegExp(r'^Container (.+) crashed \(exit (-?\d+)\)$'): (l, m) =>
      l.f('alMsgCrashed', {'name': m[1], 'code': m[2]}),
  RegExp(r'^Container (.+) restarted \(count (\d+)\)$'): (l, m) =>
      l.f('alMsgRestarted', {'name': m[1], 'n': m[2]}),
  RegExp(r'^Agent is not responding — the VPS itself still answers$'): (l, m) => l.t('alMsgAgentDown'),
  RegExp(r'^VPS offline — no answer on its address$'): (l, m) => l.t('alMsgOffline'),
};

String alertMessage(L l, Alert a) => localizeAlertText(l, a.message);

String localizeAlertText(L l, String message) {
  for (final e in _templates.entries) {
    final m = e.key.firstMatch(message);
    if (m != null) return e.value(l, m);
  }
  return message;
}

/// "cpu_high" → "High CPU", in the interface language.
String alertTypeLabel(L l, String type) {
  final key = 'alType_$type';
  final s = l.t(key);
  return s == key ? type.replaceAll('_', ' ') : s;
}
