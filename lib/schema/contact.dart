import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:nkn_sdk_flutter/utils/hex.dart';
import 'package:nkn_sdk_flutter/wallet.dart';
import 'package:nmobile/common/contact/contact.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/path.dart';
import 'package:nmobile/utils/utils.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

import 'option.dart';

class ContactSchema {
  int id; // <- id
  String type; // (required) <-> type
  String clientAddress; // (required : (ID).PubKey) <-> address
  String nknWalletAddress; // == extraInfo[nknWalletAddress] <-> data[nknWalletAddress]
  String firstName; // (required : name) <-> first_name
  String lastName; // <-> last_name
  String notes; // == extraInfo[notes] <-> data[notes]
  Map extraInfo; // [*]<-> data[*, remark_avatar, remark_name, notes, nknWalletAddress, ..., avatar, firstName]

  String avatar; // (local_path) <-> avatar
  OptionsSchema options; // <-> options
  DateTime createdTime; // <-> created_time
  DateTime updatedTime; // <-> updated_time
  String profileVersion; // <-> profile_version
  DateTime profileExpiresAt; // <-> profile_expires_at(long)

  bool isTop; // <-> is_top
  String deviceToken; // <-> device_token
  bool notificationOpen; // <-> notification_open

  ContactSchema({
    this.id,
    this.type,
    this.clientAddress,
    this.nknWalletAddress,
    this.firstName,
    this.lastName,
    this.notes,
    this.extraInfo,
    this.avatar,
    this.options,
    this.createdTime,
    this.updatedTime,
    this.profileVersion,
    this.profileExpiresAt,
    this.isTop = false,
    this.deviceToken,
    this.notificationOpen = false,
  }) {
    if (options == null) {
      options = OptionsSchema();
    }
  }

  static Future<ContactSchema> fromMap(Map e) async {
    if (e == null) {
      return null;
    }
    var contact = ContactSchema(
      id: e['id'],
      type: e['type'],
      clientAddress: e['address'],
      firstName: e['first_name'] ?? getDefaultName(e['address']),
      lastName: e['last_name'],
      avatar: e['avatar'],
      createdTime: e['created_time'] != null ? DateTime.fromMillisecondsSinceEpoch(e['created_time']) : null,
      updatedTime: e['updated_time'] != null ? DateTime.fromMillisecondsSinceEpoch(e['updated_time']) : null,
      profileVersion: e['profile_version'],
      profileExpiresAt: e['profile_expires_at'] != null ? DateTime.fromMillisecondsSinceEpoch(e['profile_expires_at']) : DateTime.now(),
      isTop: e['is_top'] == 1 ? true : false,
      deviceToken: e['device_token'],
      notificationOpen: (e['notification_open'] != null && e['notification_open'].toString() == '1') ? true : false,
    );

    if (e['data'] != null) {
      try {
        Map<String, dynamic> data = jsonDecode(e['data']);

        if (contact.extraInfo == null) {
          contact.extraInfo = new Map<String, dynamic>();
        }
        contact.extraInfo.addAll(data);

        contact.nknWalletAddress = data['nknWalletAddress'];
        if (contact.nknWalletAddress == null || contact.nknWalletAddress.isEmpty) {
          contact.nknWalletAddress = await Wallet.pubKeyToWalletAddr(getPublicKeyByClientAddr(contact.clientAddress));
        }

        contact.notes = data['notes'];
      } on FormatException catch (e) {
        logger.e(e);
      }
    }

    if (e['options'] != null) {
      try {
        Map<String, dynamic> options = jsonDecode(e['options']);
        contact.options = OptionsSchema(
          updateBurnAfterTime: options['updateBurnAfterTime'],
          deleteAfterSeconds: options['deleteAfterSeconds'],
          backgroundColor: Color(options['backgroundColor']),
          color: Color(options['color']),
        );
      } on FormatException catch (e) {
        logger.e(e);
      }
    }
    if (contact.options == null) {
      contact.options = OptionsSchema();
    }
    return contact;
  }

  Future<Map<String, dynamic>> toMap() async {
    if (extraInfo == null) {
      extraInfo = new Map<String, dynamic>();
    }
    if (nknWalletAddress != null) {
      extraInfo['nknWalletAddress'] = nknWalletAddress;
    } else if (clientAddress != null) {
      extraInfo['nknWalletAddress'] = await Wallet.pubKeyToWalletAddr(getPublicKeyByClientAddr(clientAddress));
    }
    if (notes != null) {
      extraInfo['notes'] = notes;
    }
    if (extraInfo.keys.length == 0) {
      extraInfo = null;
    }

    if (options == null) {
      options = OptionsSchema();
    }

    Map<String, dynamic> map = {
      'type': type,
      'address': clientAddress,
      'first_name': firstName ?? getDefaultName(clientAddress),
      'last_name': lastName,
      'data': extraInfo != null ? jsonEncode(extraInfo) : '{}',
      'options': jsonEncode(options.toMap()),
      'avatar': avatar != null ? Path.getLocalContactAvatar(hexEncode(chat.publicKey), Path.getFileName(avatar)) : null,
      'created_time': createdTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
      'updated_time': updatedTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
      'profile_version': profileVersion,
      'profile_expires_at': profileExpiresAt?.millisecondsSinceEpoch,
      'is_top': isTop ? 1 : 0,
      'device_token': deviceToken,
      'notification_open': notificationOpen ? 1 : 0,
    };
    return map;
  }

  static Future<ContactSchema> getByTypeMe(String clientAddress) async {
    if (clientAddress == null || clientAddress.isEmpty) return null;
    var walletAddress = await Wallet.pubKeyToWalletAddr(getPublicKeyByClientAddr(clientAddress));
    return ContactSchema(
      type: ContactType.me,
      clientAddress: clientAddress,
      nknWalletAddress: walletAddress,
      createdTime: DateTime.now(),
      updatedTime: DateTime.now(),
      profileVersion: Uuid().v4(),
    );
  }

  static getDefaultName(String clientAddress) {
    if (clientAddress == null || clientAddress.isEmpty) return null;
    String defaultName;
    var index = clientAddress.lastIndexOf('.');
    if (index < 0) {
      defaultName = clientAddress.substring(0, 6);
    } else {
      defaultName = clientAddress.substring(0, index + 7);
    }
    return defaultName;
  }

  bool get isMe {
    if (type != null && type == ContactType.me) {
      return true;
    } else {
      return false;
    }
  }

  String get getDisplayName {
    String displayName;

    if (extraInfo != null && extraInfo.isNotEmpty) {
      if (extraInfo['remark_name'] != null && extraInfo['remark_name'].isNotEmpty) {
        displayName = extraInfo['remark_name'];
      }
      // SUPPORT:START
      else if (extraInfo['firstName'] != null && extraInfo['firstName'].isNotEmpty) {
        displayName = extraInfo['firstName'];
      } else if (extraInfo['notes'] != null && extraInfo['notes'].isNotEmpty) {
        displayName = extraInfo['notes'];
      }
      // SUPPORT:END
    }

    if (displayName == null || displayName.isEmpty) {
      if (firstName != null && firstName.isNotEmpty) {
        displayName = firstName;
      }
    }

    if (displayName == null || displayName.isEmpty) {
      displayName = getDefaultName(clientAddress);
    }
    return displayName;
  }

  String get getDisplayAvatarPath {
    String avatarLocalPath;

    if (extraInfo != null && extraInfo.isNotEmpty) {
      if (extraInfo['remark_avatar'] != null && extraInfo['remark_avatar'].isNotEmpty) {
        avatarLocalPath = extraInfo['remark_avatar'];
      }
      // SUPPORT:START
      if (extraInfo['avatar'] != null && extraInfo['avatar'].isNotEmpty) {
        avatarLocalPath = extraInfo['avatar'];
      }
      // SUPPORT:END
    }

    if (avatarLocalPath == null || avatarLocalPath.isEmpty) {
      if (avatar != null && avatar.isNotEmpty) {
        avatarLocalPath = avatar;
      }
    }
    if (avatarLocalPath == null || avatarLocalPath.isEmpty) {
      return null;
    } else {
      return join(Global.applicationRootDirectory.path, avatarLocalPath);
    }
  }

  @override
  String toString() {
    return 'ContactSchema{id: $id, type: $type, clientAddress: $clientAddress, nknWalletAddress: $nknWalletAddress, firstName: $firstName, lastName: $lastName, notes: $notes, extraInfo: $extraInfo, avatar: $avatar, options: $options, createdTime: $createdTime, updatedTime: $updatedTime, profileVersion: $profileVersion, profileExpiresAt: $profileExpiresAt, isTop: $isTop, deviceToken: $deviceToken, notificationOpen: $notificationOpen}';
  }
}
