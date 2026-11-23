import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host side of `flutter drive`: saves device screenshots to build/device_shots/.
Future<void> main() => integrationDriver(onScreenshot: (name, bytes, [args]) async {
      File('build/device_shots/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      return true;
    });
