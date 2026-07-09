import 'dart:io';
import 'package:flutter/foundation.dart';
import 'lib/backend/tailscale_exposure.dart';

void main() async {
  print('Ensuring firewall...');
  await ensureBackendTailnetExposure();
  print('Done.');
  exit(0);
}
