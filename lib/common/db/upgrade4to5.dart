import 'dart:convert';
import 'dart:ui';

import 'package:nmobile/common/db/db.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/option.dart';
import 'package:nmobile/schema/subscriber.dart';
import 'package:nmobile/schema/topic.dart';
import 'package:nmobile/storages/contact.dart';
import 'package:nmobile/storages/device_info.dart';
import 'package:nmobile/storages/session.dart';
import 'package:nmobile/storages/subscriber.dart';
import 'package:nmobile/storages/topic.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/path.dart';
import 'package:nmobile/utils/utils.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class Upgrade4to5 {
  static Future upgradeContact(Database db) async {
    // id (NULL) -> id (NOT NULL)
    // address (TEXT) -> address (VARCHAR(200))
    // type (TEXT) -> type (INT)
    // created_time (INTEGER) -> create_at (BIGINT)
    // updated_time (INTEGER) -> update_at (BIGINT)
    // avatar (TEXT) -> avatar (TEXT)
    // first_name (TEXT) -> first_name (VARCHAR(50))
    // last_name (TEXT) -> last_name (VARCHAR(50))
    // profile_version (TEXT) -> profile_version (VARCHAR(300))
    // profile_expires_at (INTEGER) -> profile_expires_at (BIGINT)
    // is_top (BOOLEAN) -> is_top (BOOLEAN)
    // device_token (TEXT) -> device_token (TEXT)
    // options (TEXT) -> options (TEXT)
    // data (TEXT) -> data( TEXT)
    // notification_open (BOOLEAN) -> options.notificationOpen

    // v5 table
    if (!(await DB.checkTableExists(db, ContactStorage.tableName))) {
      await db.execute(ContactStorage.createSQL);
    }

    // v2 table
    String oldTableName = "Contact";
    if (!(await DB.checkTableExists(db, oldTableName))) {
      logger.i("Upgrade4to5 - $oldTableName no exist");
      return;
    }

    // convert all v2Data to v5Data
    int total = 0;
    int offset = 0;
    int limit = 50;
    bool loop = true;
    while (loop) {
      List<Map<String, dynamic>>? results = await db.query(oldTableName, columns: ['*'], offset: offset, limit: limit);
      if (results == null || results.isEmpty) {
        loop = false;
        // delete old table
        int count = await db.delete(oldTableName);
        if (count <= 0) {
          logger.w("Upgrade4to5 - $oldTableName delete - fail");
        } else {
          logger.i("Upgrade4to5 - $oldTableName delete - success");
        }
        break;
      } else {
        offset += limit;
        logger.i("Upgrade4to5 - $oldTableName offset++ - offset:$offset");
      }

      // loop offset:limit
      for (var i = 0; i < results.length; i++) {
        Map<String, dynamic> result = results[i];

        // address
        String? oldAddress = result["address"];
        if (oldAddress == null || oldAddress.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName query - address is null - data:$result");
        }
        String? newAddress = ((oldAddress?.isNotEmpty == true) && (oldAddress!.length <= 200)) ? oldAddress : null;
        if (newAddress == null || newAddress.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName convert - address error - data:$result");
          continue;
        }
        // type
        String? oldType = result["type"];
        if (oldType == null || oldType.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName query - type is null - data:$result");
        }
        int newType = ContactType.none;
        if (oldType == 'me') {
          newType = ContactType.me;
        } else if (oldType == 'stranger') {
          newType = ContactType.stranger;
        } else if (oldType == 'friend') {
          newType = ContactType.friend;
        }
        // at
        int? oldCreateAt = result["created_time"];
        int? oldUpdateAt = result["updated_time"];
        if (oldCreateAt == null || oldCreateAt == 0 || oldUpdateAt == null || oldUpdateAt == 0) {
          logger.w("Upgrade4to5 - $oldTableName query - at is null - data:$result");
        }
        int newCreateAt = (oldCreateAt == null || oldCreateAt == 0) ? DateTime.now().millisecondsSinceEpoch : oldCreateAt;
        int newUpdateAt = (oldUpdateAt == null || oldUpdateAt == 0) ? DateTime.now().millisecondsSinceEpoch : oldUpdateAt;
        // profile
        String? newAvatar = Path.getLocalFile(result["avatar"]);
        String? newFirstName = ((result["first_name"]?.toString().length ?? 0) > 50) ? result["first_name"]?.toString().substring(0, 50) : result["first_name"];
        String? newLastName = ((result["last_name"]?.toString().length ?? 0) > 50) ? result["last_name"]?.toString().substring(0, 50) : result["last_name"];
        // profileExtra
        String? newProfileVersion = (((result["profile_version"]?.toString().length ?? 0) > 300) ? result["profile_version"]?.toString().substring(0, 300) : result["profile_version"]) ?? Uuid().v4();
        String? newProfileExpireAt = result["profile_expires_at"] ?? (DateTime.now().millisecondsSinceEpoch - Global.profileExpireMs);
        // top + token
        int newIsTop = result["is_top"] ?? 0;
        String? newDeviceToken = result["device_token"];
        // options
        OptionsSchema newOptionsSchema = OptionsSchema();
        try {
          Map<String, dynamic>? oldOptionsMap = (result["options"]?.toString().isNotEmpty == true) ? jsonDecode(result['options']) : null;
          if (oldOptionsMap != null && oldOptionsMap.isNotEmpty) {
            newOptionsSchema.deleteAfterSeconds = oldOptionsMap['deleteAfterSeconds'];
            newOptionsSchema.updateBurnAfterAt = oldOptionsMap['updateTime'];
            newOptionsSchema.avatarBgColor = oldOptionsMap['backgroundColor'] != null ? Color(oldOptionsMap['backgroundColor']) : null;
            newOptionsSchema.avatarNameColor = oldOptionsMap['color'] != null ? Color(oldOptionsMap['color']) : null;
          }
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - options(old) error - data:$result");
        }
        newOptionsSchema.notificationOpen = result["notification_open"] ?? false;
        String? newOptions;
        try {
          newOptions = jsonEncode(newOptionsSchema.toMap());
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - options(new) error - data:$result");
        }
        // data
        Map<String, dynamic> oldDataMap;
        try {
          oldDataMap = (result['data']?.toString().isNotEmpty == true) ? jsonDecode(result['data']) : Map();
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - data(old) error - data:$result");
          oldDataMap = Map();
        }
        Map<String, dynamic> newDataMap = Map();
        newDataMap['nknWalletAddress'] = oldDataMap['nknWalletAddress']; // too loong to check
        newDataMap['notes'] = oldDataMap['notes'];
        newDataMap['avatar'] = oldDataMap['remark_avatar'];
        newDataMap['firstName'] = oldDataMap['firstName'] ?? oldDataMap['remark_name'] ?? oldDataMap['notes'];
        String? newData;
        try {
          newData = jsonEncode(newDataMap);
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - data(new) error - data:$result");
        }

        // insert v5Data
        Map<String, dynamic> entity = {
          "address": newAddress,
          "type": newType,
          "create_at": newCreateAt,
          "update_at": newUpdateAt,
          "avatar": newAvatar,
          "first_name": newFirstName,
          "last_name": newLastName,
          "profile_version": newProfileVersion,
          "profile_expires_at": newProfileExpireAt,
          "is_top": newIsTop,
          "device_token": newDeviceToken,
          "options": newOptions,
          "data": newData,
        };
        int count = await db.insert(ContactStorage.tableName, entity);
        if (count > 0) {
          logger.d("Upgrade4to5 - ${ContactStorage.tableName} added success - data:$entity");
        } else {
          logger.w("Upgrade4to5 - ${ContactStorage.tableName} added fail - data:$entity");
        }
        total += count;
      }
    }
    logger.i("Upgrade4to5 - ${ContactStorage.tableName} add end - total:$total");
  }

  static Future createDeviceInfo(Database db) async {
    await DeviceInfoStorage.create(db);
  }

  static Future upgradeTopic(Database db) async {
    // id (NULL) -> id (NOT NULL)
    // topic (TEXT) -> topic (VARCHAR(200))
    // ??/type (INTEGER) -> type (INT)
    // ?? -> create_at (BIGINT)
    // ?? -> update_at (BIGINT)
    // ??/joined (BOOLEAN) -> joined (BOOLEAN)
    // ??/time_update (INTEGER) -> subscribe_at (BIGINT)
    // expire_at (INTEGER) -> expire_height (BIGINT)
    // avatar (TEXT) -> avatar (TEXT)
    // count (INTEGER) -> count (INT)
    // is_top (BOOLEAN) -> is_top (BOOLEAN)
    // options (TEXT) -> options (TEXT)
    // ?? -> data (TEXT)
    // accept_all (BOOLEAN) -> ??
    // theme_id (INTEGER) -> ??

    // v5 table
    if (!(await DB.checkTableExists(db, TopicStorage.tableName))) {
      await db.execute(TopicStorage.createSQL);
    }

    // v2 table
    String oldTableName = 'topic';
    if (!(await DB.checkTableExists(db, oldTableName))) {
      logger.i("Upgrade4to5 - $oldTableName no exist");
      return;
    }

    // convert all v2Data to v5Data
    int total = 0;
    int offset = 0;
    int limit = 50;
    bool loop = true;
    while (loop) {
      List<Map<String, dynamic>>? results = await db.query(oldTableName, columns: ['*'], offset: offset, limit: limit);
      if (results == null || results.isEmpty) {
        loop = false;
        // delete old table
        int count = await db.delete(oldTableName);
        if (count <= 0) {
          logger.w("Upgrade4to5 - $oldTableName delete - fail");
        } else {
          logger.i("Upgrade4to5 - $oldTableName delete - success");
        }
        break;
      } else {
        offset += limit;
        logger.i("Upgrade4to5 - $oldTableName offset++ - offset:$offset");
      }

      // loop offset:limit
      for (var i = 0; i < results.length; i++) {
        Map<String, dynamic> result = results[i];

        // address
        String? oldTopic = result["topic"];
        if (oldTopic == null || oldTopic.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName query - topic is null - data:$result");
        }
        String? newTopic = ((oldTopic?.isNotEmpty == true) && (oldTopic!.length <= 200)) ? oldTopic : null;
        if (newTopic == null || newTopic.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName convert - topic error - data:$result");
          continue;
        }
        // type
        int? oldType = result["type"];
        if (oldType == null) {
          logger.w("Upgrade4to5 - $oldTableName query - type is null - data:$result");
        }
        int newType;
        if (oldType != null && (oldType == TopicType.privateTopic || oldType == TopicType.privateTopic)) {
          newType = oldType;
        } else {
          newType = isPrivateTopicReg(newTopic) ? TopicType.privateTopic : TopicType.publicTopic;
        }
        // at
        int? oldCreateAt = result["time_update"];
        int? oldUpdateAt = result["time_update"];
        if (oldCreateAt == null || oldCreateAt == 0 || oldUpdateAt == null || oldUpdateAt == 0) {
          logger.w("Upgrade4to5 - $oldTableName query - at is null - data:$result");
        }
        int newCreateAt = (oldCreateAt == null || oldCreateAt == 0) ? DateTime.now().millisecondsSinceEpoch : oldCreateAt;
        int newUpdateAt = (oldUpdateAt == null || oldUpdateAt == 0) ? DateTime.now().millisecondsSinceEpoch : oldUpdateAt;
        // joined
        int newJoined = result["joined"] ?? 1;
        // subscribe_at + expire_height
        int? newSubscribeAt = result["time_update"];
        int? newExpireHeight = result["expire_at"];
        // profile
        String? newAvatar = Path.getLocalFile(result["avatar"]);
        // count + top
        int? newCount = result["count"];
        int newIsTop = result["is_top"] ?? 0;
        // options
        OptionsSchema newOptionsSchema = OptionsSchema();
        try {
          Map<String, dynamic>? oldOptionsMap = (result["options"]?.toString().isNotEmpty == true) ? jsonDecode(result['options']) : null;
          if (oldOptionsMap != null && oldOptionsMap.isNotEmpty) {
            newOptionsSchema.deleteAfterSeconds = oldOptionsMap['deleteAfterSeconds'];
            newOptionsSchema.updateBurnAfterAt = oldOptionsMap['updateTime'];
            newOptionsSchema.avatarBgColor = oldOptionsMap['backgroundColor'] != null ? Color(oldOptionsMap['backgroundColor']) : null;
            newOptionsSchema.avatarNameColor = oldOptionsMap['color'] != null ? Color(oldOptionsMap['color']) : null;
          }
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - options(old) error - data:$result");
        }
        String? newOptions;
        try {
          newOptions = jsonEncode(newOptionsSchema.toMap());
        } catch (e) {
          handleError(e);
          logger.w("Upgrade4to5 - $oldTableName query - options(new) error - data:$result");
        }

        // insert v5Data
        Map<String, dynamic> entity = {
          'topic': newTopic,
          'type': newType,
          'create_at': newCreateAt,
          'update_at': newUpdateAt,
          'joined': newJoined,
          'subscribe_at': newSubscribeAt,
          'expire_height': newExpireHeight,
          'avatar': newAvatar,
          'count': newCount,
          'is_top': newIsTop,
          'options': newOptions,
          'data': null,
        };
        int count = await db.insert(TopicStorage.tableName, entity);
        if (count > 0) {
          logger.d("Upgrade4to5 - ${TopicStorage.tableName} added success - data:$entity");
        } else {
          logger.w("Upgrade4to5 - ${TopicStorage.tableName} added fail - data:$entity");
        }
        total += count;
      }
    }
    logger.i("Upgrade4to5 - ${TopicStorage.tableName} add end - total:$total");
  }

  static Future upgradeSubscriber(Database db) async {
    // id (NULL) -> id (NOT NULL)
    // topic (TEXT) -> topic (VARCHAR(200))
    // chat_id (TEXT) -> chat_id (VARCHAR(200))
    // time_create (INTEGER) -> create_at (BIGINT)
    // ??? -> update_at (BIGINT)
    // member_status (BOOLEAN) -> status (INT)
    // prm_p_i (INTEGER) -> perm_page (INT)
    // ??? -> data (TEXT)
    // uploaded (BOOLEAN) -> ???
    // subscribed (BOOLEAN) -> ???
    // upload_done (BOOLEAN) -> ???
    // expire_at (INTEGER) -> ???

    // v5 table
    if (!(await DB.checkTableExists(db, SubscriberStorage.tableName))) {
      await db.execute(SubscriberStorage.createSQL);
    }

    // v4 table
    String oldTableName = "subscriber";
    if (!(await DB.checkTableExists(db, oldTableName))) {
      logger.i("Upgrade4to5 - $oldTableName no exist");
      return;
    }

    // convert all v4Data to v5Data
    int total = 0;
    int offset = 0;
    int limit = 50;
    bool loop = true;
    while (loop) {
      List<Map<String, dynamic>>? results = await db.query(oldTableName, columns: ['*'], offset: offset, limit: limit);
      if (results == null || results.isEmpty) {
        loop = false;
        // delete old table
        int count = await db.delete(oldTableName);
        if (count <= 0) {
          logger.w("Upgrade4to5 - $oldTableName delete - fail");
        } else {
          logger.i("Upgrade4to5 - $oldTableName delete - success");
        }
        break;
      } else {
        offset += limit;
        logger.i("Upgrade4to5 - $oldTableName offset++ - offset:$offset");
      }

      // loop offset:limit
      for (var i = 0; i < results.length; i++) {
        Map<String, dynamic> result = results[i];

        // topic
        String? oldTopic = result["topic"];
        if (oldTopic == null || oldTopic.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName query - topic is null - data:$result");
        }
        String? newTopic = ((oldTopic?.isNotEmpty == true) && (oldTopic!.length <= 200)) ? oldTopic : null;
        if (newTopic == null || newTopic.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName convert - chat_id error - data:$result");
          continue;
        }
        // chatId
        String? oldChatId = result["chat_id"];
        if (oldChatId == null || oldChatId.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName query - chat_id is null - data:$result");
        }
        String? newChatId = ((oldChatId?.isNotEmpty == true) && (oldChatId!.length <= 200)) ? oldChatId : null;
        if (newChatId == null || newChatId.isEmpty) {
          logger.w("Upgrade4to5 - $oldTableName convert - chat_id error - data:$result");
          continue;
        }
        // at
        int? oldCreateAt = result["time_create"];
        if (oldCreateAt == null || oldCreateAt == 0) {
          logger.w("Upgrade4to5 - $oldTableName query - at is null - data:$result");
        }
        int newCreateAt = (oldCreateAt == null || oldCreateAt == 0) ? (DateTime.now().millisecondsSinceEpoch - Global.txPoolDelayMs) : oldCreateAt;
        int newUpdateAt = newCreateAt;
        // type
        int? oldStatus = result["type"];
        if (oldStatus == null) {
          logger.w("Upgrade4to5 - $oldTableName query - status is null - data:$result");
        }
        int newStatus = SubscriberStatus.None;
        if (oldStatus == 0 || oldStatus == 1 || oldStatus == 2 || oldStatus == 3) {
          newStatus = oldStatus!;
        } else if (oldStatus == 4 || oldStatus == 5) {
          newStatus = SubscriberStatus.Unsubscribed;
        }
        // permPage
        int? newPermPage = result["prm_p_i"];
        if (newPermPage == null || newPermPage < 0) {
          logger.w("Upgrade4to5 - $oldTableName query - permPage is null - data:$result");
        }

        // insert v5Data
        Map<String, dynamic> entity = {
          'topic': newTopic,
          'chat_id': newChatId,
          'create_at': newCreateAt,
          'update_at': newUpdateAt,
          'status': newStatus,
          'perm_page': newPermPage,
          'data': null,
        };
        int count = await db.insert(SubscriberStorage.tableName, entity);
        if (count > 0) {
          logger.d("Upgrade4to5 - ${SubscriberStorage.tableName} added success - data:$entity");
        } else {
          logger.w("Upgrade4to5 - ${SubscriberStorage.tableName} added fail - data:$entity");
        }
        total += count;
      }
    }
    logger.i("Upgrade4to5 - ${SubscriberStorage.tableName} add end - total:$total");
  }

  static Future upgradeMessages(Database db) async {
    // TODO:GG db messages
    // TODO:GG delete message(receipt) + read message(piece + contactOptions)
  }

  static Future createSession(Database db) async {
    await SessionStorage.create(db);
    // TODO:GG 取消息的最后一条，聚合成session，还有未读数等其他字段
    // await db.execute('ALTER TABLE $subsriberTable ADD COLUMN member_status BOOLEAN DEFAULT 0');
  }
}
