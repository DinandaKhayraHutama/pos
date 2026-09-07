import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:nti_pos/main.dart' as app;

/// Entry point for integration tests / flutter_driver.
/// Enables the driver extension then runs the real app.
void main() {
  enableFlutterDriverExtension();
  WidgetsApp.debugAllowBannerOverride = false;
  app.main();
}
