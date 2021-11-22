import 'package:local_auth/local_auth.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/settings.dart';
import 'package:nmobile/components/dialog/bottom.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/helpers/validation.dart';

/// Biometric authentication (Face ID, Touch ID or lock code), pin code, wallet password
class Authorization {
  /// This class provides means to perform local, on-device authentication of the user.
  /// This means referring to biometric authentication on iOS (Touch ID or lock code) and the fingerprint
  /// APIs on Android (introduced in Android 6.0).
  /// doc: https://github.com/flutter/plugins/tree/master/packages/local_auth
  LocalAuthentication _localAuth = LocalAuthentication();

  Future<bool> get canCheckBiometrics async => await _localAuth.canCheckBiometrics;

  Future<List<BiometricType>> get availableBiometrics async => await _localAuth.getAvailableBiometrics();

  Authorization();

  Future<bool> authentication([String? localizedReason]) async {
    if (localizedReason == null || localizedReason.isEmpty) {
      localizedReason = Global.locale((s) => s.authenticate_to_access);
    }
    try {
      bool success = await _localAuth.authenticate(
        localizedReason: localizedReason,
        useErrorDialogs: true,
        stickyAuth: true,
        biometricOnly: true,
      );
      return success;
    } catch (e) {
      handleError(e);
    }
    return false;
  }

  Future<bool> authenticationIfSupport([String? localizedReason]) async {
    if (await canCheckBiometrics) {
      return authentication(localizedReason);
    }
    return false;
  }

  Future<bool> cancelAuthentication() {
    return _localAuth.stopAuthentication();
  }

  Future<String?> getWalletPassword(String? walletAddress) {
    if (walletAddress == null || walletAddress.isEmpty) {
      return Future.value(null);
    }
    return Future(() async {
      if (Settings.biometricsAuthentication) {
        return authenticationIfSupport();
      }
      return false;
    }).then((bool authOk) async {
      String? pwd = await walletCommon.getPassword(walletAddress);
      if (!authOk || pwd == null || pwd.isEmpty) {
        return BottomDialog.of(Global.appContext).showInput(
          title: Global.locale((s) => s.verify_wallet_password),
          inputTip: Global.locale((s) => s.wallet_password),
          inputHint: Global.locale((s) => s.input_password),
          actionText: Global.locale((s) => s.continue_text),
          validator: Validator.of(Global.appContext).password(),
          password: true,
        );
      }
      return pwd;
    });
  }
}
