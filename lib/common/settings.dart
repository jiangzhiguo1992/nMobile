import 'package:nmobile/storages/settings.dart';

class NotificationType {
  static const int only_name = 0;
  static const int name_and_message = 1;
  static const int none = 2;
}

class Settings {
  static bool debug = true;
  static String appName = "nMobile";
  static String sentryDSN = 'https://c4d9d78cefc7457db9ade3f8026e9a34@o466976.ingest.sentry.io/5483254';

  static late String locale;
  static late int notificationType;
  static late bool biometricsAuthentication;

  static late Duration profileExpireDuration = Duration(seconds: 30); // TODO:GG test hour 1
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
