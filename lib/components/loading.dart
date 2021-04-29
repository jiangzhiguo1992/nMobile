import 'package:bot_toast/bot_toast.dart';

class Loading {
  static show() {
    BotToast.showLoading();
  }

  static dispose() {
    BotToast.closeAllLoading();
  }
}
