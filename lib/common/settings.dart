import 'dart:io';

import 'package:nmobile/storages/settings.dart';

class NotificationType {
  static const int only_name = 0;
  static const int name_and_message = 1;
  static const int none = 2;
}

class PlatformName {
  static const String android = "android";
  static const String ios = "ios";

  static String get() {
    return Platform.isAndroid ? android : (Platform.isIOS ? ios : "");
  }
}

class Settings {
  static const bool debug = true;
  static const String appName = "nMobile";
  static const String sentryDSN = 'https://c4d9d78cefc7457db9ade3f8026e9a34@o466976.ingest.sentry.io/5483254';
  static const String fcmServerToken = "Add Your Firebase server token";

  // notification
  static late String locale;
  static late int notificationType;
  static late bool biometricsAuthentication;

  // duration
  static late int profileExpireMs = 1 * 60 * 60 * 1000; // 1h
  static late int deviceInfoExpireMs = 1 * 60 * 60 * 1000; // 1h
  static late int txPoolDelayMs = 5 * 60 * 1000; // 5m
  static late Duration msgResendDuration = Duration(minutes: 3);

  static init() async {
    SettingsStorage settingsStorage = SettingsStorage();
    // load language
    Settings.locale = (await settingsStorage.getSettings(SettingsStorage.LOCALE_KEY)) ?? 'auto';
    // load notification type
    Settings.notificationType = (await settingsStorage.getSettings(SettingsStorage.NOTIFICATION_TYPE_KEY)) ?? NotificationType.only_name;
    // load biometrics authentication
    Settings.biometricsAuthentication = (await settingsStorage.getSettings(SettingsStorage.BIOMETRICS_AUTHENTICATION)) ?? false;
  }
}
