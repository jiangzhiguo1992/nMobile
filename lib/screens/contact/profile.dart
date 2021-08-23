import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nkn_sdk_flutter/utils/hex.dart';
import 'package:nmobile/blocs/wallet/wallet_bloc.dart';
import 'package:nmobile/blocs/wallet/wallet_event.dart';
import 'package:nmobile/blocs/wallet/wallet_state.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/push/device_token.dart';
import 'package:nmobile/components/base/stateful.dart';
import 'package:nmobile/components/button/button.dart';
import 'package:nmobile/components/contact/avatar_editable.dart';
import 'package:nmobile/components/dialog/bottom.dart';
import 'package:nmobile/components/dialog/loading.dart';
import 'package:nmobile/components/dialog/modal.dart';
import 'package:nmobile/components/layout/expansion_layout.dart';
import 'package:nmobile/components/layout/header.dart';
import 'package:nmobile/components/layout/layout.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/components/tip/toast.dart';
import 'package:nmobile/generated/l10n.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/helpers/media_picker.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/wallet.dart';
import 'package:nmobile/screens/chat/messages.dart';
import 'package:nmobile/screens/contact/chat_profile.dart';
import 'package:nmobile/utils/asset.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/path.dart';
import 'package:uuid/uuid.dart';

class ContactProfileScreen extends BaseStateFulWidget {
  static const String routeName = '/contact/profile';
  static final String argContactSchema = "contact_schema";
  static final String argContactId = "contact_id";
  static final String argContactClientAddress = "contact_client_address";

  static Future go(BuildContext context, {ContactSchema? schema, int? contactId, String? clientAddress}) {
    logger.d("ContactProfileScreen - go - id:$contactId - clientAddress:$clientAddress - schema:$schema");
    if (schema == null && (contactId == null || contactId == 0)) return Future.value(null);
    return Navigator.pushNamed(context, routeName, arguments: {
      argContactSchema: schema,
      argContactId: contactId,
      argContactClientAddress: clientAddress,
    });
  }

  final Map<String, dynamic>? arguments;

  ContactProfileScreen({Key? key, this.arguments}) : super(key: key);

  @override
  _ContactProfileScreenState createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends BaseStateFulWidgetState<ContactProfileScreen> {
  static List<Duration> burnValueArray = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
    Duration(days: 7),
  ];

  static List<String> burnTextArray(BuildContext context) {
    return [
      S.of(context).burn_5_seconds,
      S.of(context).burn_10_seconds,
      S.of(context).burn_30_seconds,
      S.of(context).burn_1_minute,
      S.of(context).burn_5_minutes,
      S.of(context).burn_10_minutes,
      S.of(context).burn_30_minutes,
      S.of(context).burn_1_hour,
      S.of(context).burn_6_hour,
      S.of(context).burn_12_hour,
      S.of(context).burn_1_day,
      S.of(context).burn_1_week,
    ];
  }

  static String getStringFromSeconds(context, int seconds) {
    int currentIndex = -1;
    for (int index = 0; index < burnValueArray.length; index++) {
      Duration duration = burnValueArray[index];
      if (seconds == duration.inSeconds) {
        currentIndex = index;
        break;
      }
    }
    if (currentIndex == -1) {
      return '';
    } else {
      return burnTextArray(context)[currentIndex];
    }
  }

  ContactSchema? _contactSchema;
  WalletSchema? _walletDefault;

  WalletBloc? _walletBloc;
  StreamSubscription? _updateContactSubscription;
  StreamSubscription? _changeWalletSubscription;

  bool _initBurnOpen = false;
  int _initBurnProgress = -1;
  bool _burnOpen = false;
  int _burnProgress = -1;

  bool _notificationOpen = false;

  @override
  void onRefreshArguments() {
    _refreshContactSchema();
  }

  @override
  initState() {
    super.initState();

    _walletBloc = BlocProvider.of<WalletBloc>(this.context);

    // listen
    _updateContactSubscription = contactCommon.updateStream.where((event) => event.id == _contactSchema?.id).listen((ContactSchema event) {
      setState(() {
        _contactSchema = event;
      });
    });
    _changeWalletSubscription = _walletBloc?.stream.listen((event) {
      if (event is WalletDefault) {
        if (_contactSchema?.type == ContactType.me) {
          _onDefaultWalletChange();
        }
      }
    });

    // init
    _refreshDefaultWallet();
  }

  @override
  void dispose() {
    _updateBurnIfNeed();
    _updateContactSubscription?.cancel();
    _changeWalletSubscription?.cancel();
    super.dispose();
  }

  _refreshContactSchema({ContactSchema? schema}) async {
    ContactSchema? contactSchema = widget.arguments![ContactProfileScreen.argContactSchema];
    int? contactId = widget.arguments![ContactProfileScreen.argContactId];
    String? contactClientAddress = widget.arguments![ContactProfileScreen.argContactClientAddress];
    if (schema != null) {
      this._contactSchema = schema;
    } else if (contactSchema != null && contactSchema.id != 0) {
      this._contactSchema = contactSchema;
    } else if (contactId != null && contactId != 0) {
      this._contactSchema = await contactCommon.query(contactId);
    } else if (contactClientAddress?.isNotEmpty == true) {
      this._contactSchema = await contactCommon.queryByClientAddress(contactClientAddress);
    }
    if (this._contactSchema == null || this._contactSchema!.clientAddress.isEmpty) return;

    // exist
    contactCommon.queryByClientAddress(this._contactSchema?.clientAddress).then((ContactSchema? exist) async {
      if (exist != null) return;
      ContactSchema? added = await contactCommon.add(this._contactSchema, notify: true, checkDuplicated: false);
      if (added == null) return;
      setState(() {
        this._contactSchema = added;
      });
    });

    // burn
    int? burnAfterSeconds = _contactSchema?.options?.deleteAfterSeconds;
    _burnOpen = burnAfterSeconds != null && burnAfterSeconds != 0;
    if (_burnOpen) {
      _burnProgress = burnValueArray.indexWhere((x) => x.inSeconds == burnAfterSeconds);
      if (burnAfterSeconds != null && burnAfterSeconds > burnValueArray.last.inSeconds) {
        _burnProgress = burnValueArray.length - 1;
      }
    }
    if (_burnProgress < 0) _burnProgress = 0;
    _initBurnOpen = _burnOpen;
    _initBurnProgress = _burnProgress;

    // notification
    if (_contactSchema?.isMe == false) {
      if (_contactSchema?.options?.notificationOpen != null) {
        _notificationOpen = _contactSchema!.options!.notificationOpen;
      } else {
        _notificationOpen = false;
      }
    }
    setState(() {});
  }

  Future _refreshDefaultWallet({WalletSchema? wallet}) async {
    WalletSchema? schema = wallet ?? await walletCommon.getDefault();
    setState(() {
      _walletDefault = schema;
    });
  }

  _onDefaultWalletChange() async {
    WalletSchema? walletDefault = await walletCommon.getDefault();
    if (walletDefault?.address == this._walletDefault?.address) return;
    await _refreshDefaultWallet(wallet: walletDefault);

    //Loading.show(); // set on func _selectDefaultWallet
    try {
      // client exit
      await clientCommon.signOut();
      await Future.delayed(Duration(seconds: 1)); // wait client close
      Loading.dismiss();

      // client entry
      if (walletDefault == null) {
        Navigator.pop(this.context);
        return;
      }
      var client = await clientCommon.signIn(walletDefault, dialogVisible: (show) => show ? Loading.show() : Loading.dismiss());
      await Future.delayed(Duration(seconds: 1)); // wait client create

      if (client != null) {
        // refresh state
        ContactSchema? _me = await contactCommon.getMe(canAdd: true);
        _refreshContactSchema(schema: _me); // await
        Toast.show(S.of(Global.appContext).tip_switch_success); // must global context
      } else {
        // pop
        Navigator.pop(this.context);
      }

      // TimerAuth.instance.enableAuth(); // TODO:GG auth
    } catch (e) {
      handleError(e);
      Navigator.pop(this.context);
    }
  }

  String _getClientAddressShow() {
    if (_contactSchema?.clientAddress != null) {
      if (_contactSchema!.clientAddress.length > 10) {
        return _contactSchema!.clientAddress.substring(0, 10) + '...';
      }
      return _contactSchema!.clientAddress;
    }
    return '';
  }

  _selectDefaultWallet() async {
    S _localizations = S.of(this.context);
    WalletSchema? result = await BottomDialog.of(this.context).showWalletSelect(title: _localizations.select_another_wallet, onlyNKN: true);
    if (result == null || result.address == _contactSchema?.nknWalletAddress) return;
    _walletBloc?.add(DefaultWallet(result.address));
    Loading.show();
    // no change chat immediately because wallet default maybe failure
    // Loading.dismiss();
  }

  _selectAvatarPicture() async {
    if (clientCommon.publicKey == null) return;
    String remarkAvatarLocalPath = Path.createLocalFile(hexEncode(clientCommon.publicKey!), SubDirType.contact, "${Uuid().v4()}.jpeg");
    String? remarkAvatarPath = Path.getCompleteFile(remarkAvatarLocalPath);
    File? picked = await MediaPicker.pickSingle(
      mediaType: MediaType.image,
      source: ImageSource.gallery,
      cropStyle: CropStyle.rectangle,
      cropRatio: CropAspectRatio(ratioX: 1, ratioY: 1),
      compressQuality: 50,
      returnPath: remarkAvatarPath,
    );
    if (picked == null) {
      // Toast.show("Open camera or MediaLibrary for nMobile to update your profile");
      return;
    }

    if (_contactSchema?.type == ContactType.me) {
      contactCommon.setSelfAvatar(_contactSchema, remarkAvatarLocalPath, notify: true); // await
    } else {
      contactCommon.setRemarkAvatar(_contactSchema, remarkAvatarLocalPath, notify: true); // await
    }
  }

  _modifyNickname() async {
    S _localizations = S.of(this.context);
    String? newName = await BottomDialog.of(this.context).showInput(
      title: _localizations.edit_nickname,
      inputTip: _localizations.edit_nickname,
      inputHint: _localizations.input_nickname,
      value: _contactSchema?.displayName,
      actionText: _localizations.save,
      maxLength: 20,
    );
    if (newName == null || newName.trim().isEmpty) return;
    if (_contactSchema?.type == ContactType.me) {
      contactCommon.setSelfName(_contactSchema, newName.trim(), "", notify: true); // await
    } else {
      contactCommon.setRemarkName(_contactSchema, newName.trim(), "", notify: true); // await
    }
  }

  _updateBurnIfNeed() {
    if (_burnOpen == _initBurnOpen && _burnProgress == _initBurnProgress) return;
    int _burnValue;
    if (!_burnOpen || _burnProgress < 0) {
      _burnValue = 0;
    } else {
      _burnValue = burnValueArray[_burnProgress].inSeconds;
    }
    int timeNow = DateTime.now().millisecondsSinceEpoch;
    _contactSchema?.options?.deleteAfterSeconds = _burnValue;
    _contactSchema?.options?.updateBurnAfterAt = timeNow;
    // inside update
    contactCommon.setOptionsBurn(_contactSchema, _burnValue, timeNow, notify: true); // await
    // outside update
    chatOutCommon.sendContactOptionsBurn(_contactSchema?.clientAddress, _burnValue, timeNow); // await
  }

  _updateNotificationAndDeviceToken() async {
    S _localizations = S.of(this.context);
    String? deviceToken = _notificationOpen ? await DeviceToken.get() : null;
    if (_notificationOpen && (deviceToken == null || deviceToken.isEmpty)) {
      setState(() {
        _notificationOpen = false;
      });
      Toast.show(_localizations.unavailable_device);
      return;
    }
    _contactSchema?.options?.notificationOpen = _notificationOpen;
    // inside update
    contactCommon.setNotificationOpen(_contactSchema, _notificationOpen, notify: true); // await
    // outside update
    chatOutCommon.sendContactOptionsToken(_contactSchema?.clientAddress, deviceToken ?? ""); // await
  }

  _addFriend() {
    S _localizations = S.of(this.context);
    if (_contactSchema == null) return;
    contactCommon.setType(_contactSchema!.id, ContactType.friend, notify: true);
    Toast.show(_localizations.success);
  }

  _deleteAction() {
    S _localizations = S.of(this.context);

    ModalDialog.of(this.context).confirm(
      title: _localizations.tip,
      content: _localizations.delete_friend_confirm_title,
      agree: Button(
        width: double.infinity,
        text: _localizations.delete_contact,
        backgroundColor: application.theme.strongColor,
        onPressed: () async {
          Navigator.pop(this.context);
          bool success = await contactCommon.delete(_contactSchema?.id, notify: true);
          if (!success) return;
          Navigator.pop(this.context);
        },
      ),
      reject: Button(
        width: double.infinity,
        text: _localizations.cancel,
        fontColor: application.theme.fontColor2,
        backgroundColor: application.theme.backgroundLightColor,
        onPressed: () => Navigator.pop(this.context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Layout(
      headerColor: application.theme.backgroundColor4,
      clipAlias: false,
      header: Header(
        backgroundColor: application.theme.backgroundColor4,
        title: S.of(context).settings,
      ),
      body: _contactSchema?.isMe == true
          ? _getSelfView()
          : _contactSchema?.isMe == false
              ? _getPersonView()
              : SizedBox.shrink(),
    );
  }

  _buttonStyle({bool topRadius = true, bool botRadius = true, double topPad = 12, double botPad = 12}) {
    return ButtonStyle(
      backgroundColor: MaterialStateProperty.resolveWith((state) => application.theme.backgroundLightColor),
      padding: MaterialStateProperty.resolveWith((states) => EdgeInsets.only(left: 16, right: 16, top: topPad, bottom: botPad)),
      shape: MaterialStateProperty.resolveWith(
        (states) => RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: topRadius ? Radius.circular(12) : Radius.zero,
            bottom: botRadius ? Radius.circular(12) : Radius.zero,
          ),
        ),
      ),
    );
  }

  _getSelfView() {
    S _localizations = S.of(this.context);

    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          Container(
            padding: EdgeInsets.only(left: 16, right: 16, bottom: 32),
            decoration: BoxDecoration(
              color: application.theme.backgroundColor4,
            ),
            child: Center(
              /// avatar
              child: _contactSchema != null
                  ? ContactAvatarEditable(
                      radius: 48,
                      contact: _contactSchema!,
                      placeHolder: false,
                      onSelect: _selectAvatarPicture,
                    )
                  : SizedBox.shrink(),
            ),
          ),
          Stack(
            children: [
              Container(
                height: 32,
                decoration: BoxDecoration(color: application.theme.backgroundColor4),
              ),
              Container(
                decoration: BoxDecoration(
                  color: application.theme.backgroundColor,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: EdgeInsets.only(left: 16, right: 16, top: 26, bottom: 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Label(
                      _localizations.my_profile,
                      type: LabelType.h3,
                    ),
                    SizedBox(height: 24),

                    /// name
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: false, topPad: 15, botPad: 10),
                      onPressed: () {
                        _modifyNickname();
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.iconSvg('user', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Label(
                            _localizations.nickname,
                            type: LabelType.bodyRegular,
                            color: application.theme.fontColor1,
                          ),
                          SizedBox(width: 20),
                          Expanded(
                            child: Label(
                              _contactSchema?.displayName ?? "",
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor2,
                              overflow: TextOverflow.fade,
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Asset.iconSvg(
                            'right',
                            width: 24,
                            color: application.theme.fontColor2,
                          ),
                        ],
                      ),
                    ),

                    /// address
                    TextButton(
                      style: _buttonStyle(topRadius: false, botRadius: false, topPad: 12, botPad: 12),
                      onPressed: () {
                        if (this._contactSchema == null) return;
                        ContactChatProfileScreen.go(this.context, this._contactSchema!);
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.image('chat/chat-id.png', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Label(
                            _localizations.d_chat_address,
                            type: LabelType.bodyRegular,
                            color: application.theme.fontColor1,
                          ),
                          SizedBox(width: 20),
                          Expanded(
                            child: Label(
                              _getClientAddressShow(),
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor2,
                              overflow: TextOverflow.fade,
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Asset.iconSvg(
                            'right',
                            width: 24,
                            color: application.theme.fontColor2,
                          ),
                        ],
                      ),
                    ),

                    /// wallet
                    TextButton(
                      style: _buttonStyle(topRadius: false, botRadius: true, topPad: 10, botPad: 15),
                      onPressed: () {
                        _selectDefaultWallet();
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.iconSvg('wallet', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Expanded(
                            child: Label(
                              _walletDefault?.name ?? "--",
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor1,
                            ),
                          ),
                          SizedBox(width: 20),
                          Label(
                            _localizations.change_default_chat_wallet,
                            type: LabelType.bodyRegular,
                            color: application.theme.primaryColor,
                            overflow: TextOverflow.fade,
                            textAlign: TextAlign.right,
                            fontWeight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _getPersonView() {
    S _localizations = S.of(this.context);

    return SingleChildScrollView(
      padding: EdgeInsets.only(top: 20, bottom: 30, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          /// avatar
          Center(
            child: _contactSchema != null
                ? ContactAvatarEditable(
                    radius: 48,
                    contact: _contactSchema!,
                    placeHolder: false,
                    onSelect: _selectAvatarPicture,
                  )
                : SizedBox.shrink(),
          ),
          SizedBox(height: 36),

          Column(
            children: <Widget>[
              /// name
              TextButton(
                style: _buttonStyle(topRadius: true, botRadius: false, topPad: 15, botPad: 10),
                onPressed: () {
                  _modifyNickname();
                },
                child: Row(
                  children: <Widget>[
                    Asset.iconSvg('user', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      _localizations.nickname,
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    SizedBox(width: 20),
                    Expanded(
                      child: Label(
                        _contactSchema?.displayName ?? "",
                        type: LabelType.bodyRegular,
                        color: application.theme.fontColor2,
                        overflow: TextOverflow.fade,
                        textAlign: TextAlign.right,
                      ),
                    ),
                    Asset.iconSvg(
                      'right',
                      width: 24,
                      color: application.theme.fontColor2,
                    ),
                  ],
                ),
              ),

              /// address
              TextButton(
                style: _buttonStyle(topRadius: false, botRadius: true, topPad: 10, botPad: 15),
                onPressed: () {
                  if (this._contactSchema == null) return;
                  ContactChatProfileScreen.go(this.context, this._contactSchema!);
                },
                child: Row(
                  children: <Widget>[
                    Asset.image('chat/chat-id.png', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      _localizations.d_chat_address,
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    SizedBox(width: 20),
                    Expanded(
                      child: Label(
                        _getClientAddressShow(),
                        type: LabelType.bodyRegular,
                        color: application.theme.fontColor2,
                        overflow: TextOverflow.fade,
                        textAlign: TextAlign.right,
                      ),
                    ),
                    Asset.iconSvg(
                      'right',
                      width: 24,
                      color: application.theme.fontColor2,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 28),

          /// burn
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 8, botPad: 8),
            onPressed: () {
              setState(() {
                _burnOpen = !_burnOpen;
              });
            },
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.max,
                  children: <Widget>[
                    Asset.image('contact/xiaohui.png', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      _localizations.burn_after_reading,
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    Spacer(),
                    CupertinoSwitch(
                      value: _burnOpen,
                      activeColor: application.theme.primaryColor,
                      onChanged: (value) {
                        setState(() {
                          _burnOpen = value;
                        });
                      },
                    ),
                  ],
                ),
                ExpansionLayout(
                  isExpanded: _burnOpen,
                  child: Container(
                    padding: EdgeInsets.only(top: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Icon(Icons.alarm_on, size: 24, color: application.theme.primaryColor),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Label(
                                  (!_burnOpen || _burnProgress < 0) ? _localizations.off : getStringFromSeconds(this.context, burnValueArray[_burnProgress].inSeconds),
                                  type: LabelType.bodyRegular,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Slider(
                                value: _burnProgress >= 0 ? _burnProgress.roundToDouble() : 0,
                                min: 0,
                                max: (burnValueArray.length - 1).roundToDouble(),
                                activeColor: application.theme.primaryColor,
                                inactiveColor: application.theme.fontColor2,
                                divisions: burnValueArray.length - 1,
                                label: burnTextArray(this.context)[_burnProgress],
                                onChanged: (value) {
                                  setState(() {
                                    _burnProgress = value.round();
                                    if (_burnProgress > burnValueArray.length - 1) {
                                      _burnProgress = burnValueArray.length - 1;
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, top: 6),
            child: Label(
              (!_burnOpen || _burnProgress < 0)
                  ? _localizations.burn_after_reading_desc
                  : _localizations.burn_after_reading_desc_disappear(
                      burnTextArray(this.context)[_burnProgress],
                    ),
              type: LabelType.bodySmall,
              fontWeight: FontWeight.w600,
              softWrap: true,
            ),
          ),
          SizedBox(height: 28),

          /// notification
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 8, botPad: 8),
            onPressed: () {
              // setState(() {
              //   _notificationOpen = !_notificationOpen;
              //   _updateNotificationAndDeviceToken();
              // });
            },
            child: Row(
              children: <Widget>[
                Asset.iconSvg('notification-bell', color: application.theme.primaryColor, width: 24),
                SizedBox(width: 10),
                Label(
                  _localizations.remote_notification,
                  type: LabelType.bodyRegular,
                  color: application.theme.fontColor1,
                ),
                Spacer(),
                CupertinoSwitch(
                  value: _notificationOpen,
                  activeColor: application.theme.primaryColor,
                  onChanged: (value) {
                    setState(() {
                      _notificationOpen = value;
                      _updateNotificationAndDeviceToken();
                    });
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
            child: Label(
              _localizations.accept_notification,
              type: LabelType.bodySmall,
              fontWeight: FontWeight.w600,
              softWrap: true,
            ),
          ),
          SizedBox(height: 28),

          /// sendMsg
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
            onPressed: () {
              _updateBurnIfNeed();
              ChatMessagesScreen.go(this.context, _contactSchema);
            },
            child: Row(
              children: <Widget>[
                Asset.iconSvg('chat', color: application.theme.primaryColor, width: 24),
                SizedBox(width: 10),
                Label(
                  _localizations.send_message,
                  type: LabelType.bodyRegular,
                  color: application.theme.fontColor1,
                ),
                Spacer(),
                Asset.iconSvg(
                  'right',
                  width: 24,
                  color: application.theme.fontColor2,
                ),
              ],
            ),
          ),
          // SizedBox(height: 28),

          /// AddContact
          _contactSchema?.type == ContactType.stranger
              ? Column(
                  children: [
                    SizedBox(height: 10),
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
                      onPressed: () {
                        _addFriend();
                      },
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.person_add, color: application.theme.primaryColor),
                          SizedBox(width: 10),
                          Label(
                            _localizations.add_contact,
                            type: LabelType.bodyRegular,
                            color: application.theme.primaryColor,
                          ),
                          Spacer(),
                        ],
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),

          /// delete
          _contactSchema?.type == ContactType.friend
              ? Column(
                  children: [
                    SizedBox(height: 28),
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
                      onPressed: () {
                        _deleteAction();
                      },
                      child: Row(
                        children: <Widget>[
                          Spacer(),
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 10),
                          Label(_localizations.delete, type: LabelType.bodyRegular, color: Colors.red),
                          Spacer(),
                        ],
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),
        ],
      ),
    );
  }
}
