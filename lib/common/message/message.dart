import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:nmobile/common/contact/device_info.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/settings.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/private_group.dart';
import 'package:nmobile/schema/session.dart';
import 'package:nmobile/storages/message.dart';
import 'package:nmobile/storages/message_piece.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/parallel_queue.dart';

class MessageCommon with Tag {
  MessageCommon();

  // ignore: close_sinks
  StreamController<MessageSchema> _onSavedController = StreamController<MessageSchema>.broadcast();
  StreamSink<MessageSchema> get onSavedSink => _onSavedController.sink;
  Stream<MessageSchema> get onSavedStream => _onSavedController.stream.distinct((prev, next) => prev.msgId == next.msgId);

  // ignore: close_sinks
  StreamController<MessageSchema> _onUpdateController = StreamController<MessageSchema>.broadcast();
  StreamSink<MessageSchema> get onUpdateSink => _onUpdateController.sink;
  Stream<MessageSchema> get onUpdateStream => _onUpdateController.stream; // .distinct((prev, next) => prev.msgId == next.msgId)

  // ignore: close_sinks
  StreamController<String> _onDeleteController = StreamController<String>.broadcast();
  StreamSink<String> get onDeleteSink => _onDeleteController.sink;
  Stream<String> get onDeleteStream => _onDeleteController.stream; // .distinct((prev, next) => prev.msgId == next.msgId)

  // ignore: close_sinks
  StreamController<Map<String, dynamic>> _onProgressController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSink<Map<String, dynamic>> get onProgressSink => _onProgressController.sink;
  Stream<Map<String, dynamic>> get onProgressStream => _onProgressController.stream.distinct((prev, next) => (next['msg_id'] == prev['msg_id']) && (next['percent'] < prev['percent']));

  Map<String, ParallelQueue> _messageQueueIdQueues = Map();
  Map<String, String?> _syncMessageQueueParams = Map();

  String? chattingTargetId;

  bool isTargetMessagePageVisible(String? targetId) {
    bool inSessionPage = chattingTargetId == targetId;
    bool isAppForeground = application.appLifecycleState == AppLifecycleState.resumed;
    bool needAuth = (application.goForegroundAt - application.goBackgroundAt) >= Settings.gapClientReAuthMs;
    bool maybeAuthing = needAuth && ((DateTime.now().millisecondsSinceEpoch - application.goForegroundAt) < 500); // wait go app_screen
    return inSessionPage && isAppForeground && !maybeAuthing && !application.inAuthProgress;
  }

  ///*********************************************************************************///
  ///************************************ Storage ************************************///
  ///*********************************************************************************///

  Future<MessageSchema?> insert(MessageSchema? schema) async {
    if (schema == null) return null;
    if (schema.contentType == MessageContentType.piece) {
      return await MessagePieceStorage.instance.insert(schema);
    }
    return await MessageStorage.instance.insert(schema);
  }

  Future<int> delete(String? msgId, String? contentType) {
    if (contentType == MessageContentType.piece) {
      return MessagePieceStorage.instance.delete(msgId);
    }
    return MessageStorage.instance.delete(msgId);
  }

  Future<bool> updateDeleteAt(String? msgId, int? deleteAt) {
    return MessageStorage.instance.updateDeleteAt(msgId, deleteAt);
  }

  Future<bool> updateSendAt(String? msgId, int? sendAt) {
    return MessageStorage.instance.updateSendAt(msgId, sendAt);
  }

  Future<bool> updatePid(String? msgId, Uint8List? pid) {
    return MessageStorage.instance.updatePid(msgId, pid);
  }

  Future<bool> updateDeviceQueueId(String? msgId, String? deviceId, int queueId) {
    return MessageStorage.instance.updateDeviceQueueId(msgId, deviceId, queueId);
  }

  Future<MessageSchema?> query(String? msgId) {
    return MessageStorage.instance.query(msgId);
  }

  Future<List<MessageSchema>> queryPieceList(String? msgId, {int offset = 0, final limit = 20}) async {
    return await MessagePieceStorage.instance.queryList(msgId, offset: offset, limit: limit);
  }

  Future<List<MessageSchema>> queryListByIds(List<String>? msgIds) {
    return MessageStorage.instance.queryListByIds(msgIds);
  }

  Future<List<MessageSchema>> queryListByTargetVisible(String? targetId, int targetType, {int offset = 0, final limit = 20}) {
    return MessageStorage.instance.queryListByTarget(targetId, targetType, isDelete: false, offset: offset, limit: limit);
  }

  Future<List<MessageSchema>> queryListByTargetTypesVisible(String? targetId, int targetType, List<String> types, {int offset = 0, final limit = 20}) {
    return MessageStorage.instance.queryListByTargetTypesWithNoDelete(targetId, targetType, types, offset: offset, limit: limit);
  }

  Future<List<MessageSchema>> queryListByTargetDeviceQueueId(String? targetId, int targetType, String? deviceId, int queueId, {int offset = 0, final limit = 20}) {
    return MessageStorage.instance.queryListByTargetDeviceQueueId(targetId, targetType, deviceId, queueId, offset: offset, limit: limit);
  }

  Future<List<MessageSchema>> queryAllSending() async {
    List<MessageSchema> messages = [];
    final limit = 20;
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> result = await MessageStorage.instance.queryListByOutboundStatus(true, MessageStatus.Sending, offset: offset, limit: limit);
      messages.addAll(result);
      if (result.length < limit) break;
    }
    return messages;
  }

  Future<List<MessageSchema>> queryAllReceivedSuccess() async {
    List<MessageSchema> messages = [];
    final limit = 20;
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> result = await MessageStorage.instance.queryListByOutboundStatus(false, MessageStatus.Success, offset: offset, limit: limit);
      messages.addAll(result);
      if (result.length < limit) break;
    }
    return messages;
  }

  Future<List<MessageSchema>> queryAllNoACKByTarget(String? targetId, int targetType, {final max = 20}) async {
    List<MessageSchema> messages = [];
    final limit = 20;
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> result = await MessageStorage.instance.queryListByTarget(targetId, targetType, isOutbound: true, status: MessageStatus.Success, offset: offset, limit: limit);
      messages.addAll(result);
      if (result.length < limit) break;
      if (messages.length > max) break;
    }
    return messages;
  }

  Future<List<MessageSchema>> queryAllByTargetOutboundStatus(String? targetId, int targetType, bool isOutbound, int status) async {
    List<MessageSchema> messages = [];
    final limit = 20;
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> result = await MessageStorage.instance.queryListByTarget(targetId, targetType, isOutbound: isOutbound, status: status, offset: offset, limit: limit);
      messages.addAll(result);
      if (result.length < limit) break;
    }
    return messages;
  }

  Future<bool> messageDelete(MessageSchema? message, {bool notify = false}) async {
    if (message == null || message.msgId.isEmpty) return false;
    bool delDeep = !message.canReceipt ? true : (message.isOutbound ? (message.status >= MessageStatus.Receipt) : (message.status >= MessageStatus.Read));
    bool? success;
    if (delDeep) {
      if (!message.isOutbound) {
        int nowAt = DateTime.now().millisecondsSinceEpoch;
        if (message.isTargetContact) {
          ContactSchema? contact = await contactCommon.query(message.targetId, fetchWalletAddress: false);
          if ((contact != null) && !contact.receivedMessages.containsKey(message.msgId)) {
            var data = await contactCommon.setReceivedMessages(message.targetId, {message.msgId: message.receiveAt ?? nowAt}, []);
            if (data == null) {
              logger.w("$TAG - messageDelete - contact setReceivedMessages fail - msgId:${message.msgId} - receivedMessages:${contact.receivedMessages} - targetId:${message.targetId}");
              success = false;
            } else {
              contact.data = data;
              logger.d("$TAG - messageDelete - contact setReceivedMessages success - count:${contact.receivedMessages.length} - msgId:${message.msgId} - receivedMessages:${contact.receivedMessages} - targetId:${message.targetId}");
            }
          } else {
            logger.v("$TAG - messageDelete - contact setReceivedMessages contains - count:${contact?.receivedMessages.length} - msgId:${message.msgId} - receivedMessages:${contact?.receivedMessages} - targetId:${message.targetId}");
          }
        } else if (message.isTargetGroup) {
          PrivateGroupSchema? group = await privateGroupCommon.queryGroup(message.targetId);
          if ((group != null) && !group.receivedMessages.containsKey(message.msgId)) {
            var data = await privateGroupCommon.setReceivedMessages(message.targetId, {message.msgId: message.receiveAt ?? nowAt}, []);
            if (data == null) {
              logger.w("$TAG - messageDelete - privateGroup setReceivedMessages fail - msgId:${message.msgId} - receivedMessages:${group.receivedMessages} - targetId:${message.targetId}");
              success = false;
            } else {
              group.data = data;
              logger.d("$TAG - messageDelete - privateGroup setReceivedMessages success - count:${group.receivedMessages.length} - msgId:${message.msgId} - receivedMessages:${group.receivedMessages} - targetId:${message.targetId}");
            }
          } else {
            logger.v("$TAG - messageDelete - privateGroup setReceivedMessages contains - count:${group?.receivedMessages.length} - msgId:${message.msgId} - receivedMessages:${group?.receivedMessages} - targetId:${message.targetId}");
          }
        }
      }
      if (success == null) {
        success = (await delete(message.msgId, message.contentType)) > 0;
        if (!success && ((await query(message.msgId)) == null)) {
          success = true;
        }
      }
    } else {
      if (!message.isDelete) {
        success = await MessageStorage.instance.updateIsDelete(message.msgId, true);
        if (success == true) message.isDelete = true;
      }
    }
    if (notify) onDeleteSink.add(message.msgId); // no need success
    // delete file
    if (delDeep && (success == true)) {
      if (message.isContentFile) {
        (message.content as File).exists().then((exist) {
          if (exist) {
            try {
              (message.content as File).delete(); // await
            } catch (e) {}
            logger.d("$TAG - messageDelete - content file delete success - path:${(message.content as File).path}");
          } else {
            // logger.v("$TAG - messageDelete - content file no Exists - path:${(message.content as File).path}");
          }
        });
      }
      String? mediaThumbnail = MessageOptions.getMediaThumbnailPath(message.options);
      if ((mediaThumbnail != null) && mediaThumbnail.isNotEmpty) {
        File(mediaThumbnail).exists().then((exist) {
          if (exist) {
            try {
              File(mediaThumbnail).delete(); // await
            } catch (e) {}
            logger.d("$TAG - messageDelete - video_thumbnail delete success - path:$mediaThumbnail");
          } else {
            // logger.v("$TAG - messageDelete - video_thumbnail no Exists - path:$mediaThumbnail");
          }
        });
      }
    }
    return success ?? false;
  }

  Future<MessageSchema> updateMessageStatus(MessageSchema message, int status, {bool force = false, int? receiveAt, bool notify = true}) async {
    // re_query
    message = (await query(message.msgId)) ?? message;
    // check
    if ((status <= message.status) && !force) {
      if (status == message.status) {
        logger.d("$TAG - updateMessageStatus - status is same - new:$status - old:${message.status} - msgId:${message.msgId}");
      } else {
        logger.w("$TAG - updateMessageStatus - status is wrong - new:$status - old:${message.status} - msgId:${message.msgId}");
      }
      return message;
    }
    // update
    logger.d("$TAG - updateMessageStatus - new:$status - old:${message.status} - msgId:${message.msgId}");
    bool success = await MessageStorage.instance.updateStatus(message.msgId, status, receiveAt: receiveAt);
    if (success) {
      message.status = status;
      if (notify) onUpdateSink.add(message);
    }
    // delete
    if (message.isDelete) {
      await messageDelete(message, notify: true);
    } else if ((message.deleteAt ?? 0) > 0) {
      logger.i("$TAG - updateMessageStatus - need delete later - status:${message.status} - message:${message.toStringSimple()}");
    }
    return message;
  }

  Future<bool> updateMessageOptions(MessageSchema? message, Map<String, dynamic>? added, {bool notify = true}) async {
    if (message == null || message.msgId.isEmpty) return false;
    logger.d("$TAG - updateMessageOptions - start - add:$added - old:${message.options} - msgId:${message.msgId}");
    Map<String, dynamic>? options = await MessageStorage.instance.updateOptions(message.msgId, added);
    if (options != null) {
      logger.d("$TAG - updateMessageOptions - end success - new:$options - msgId:${message.msgId}");
      message.options = options;
      if (notify) onUpdateSink.add(message);
    } else {
      logger.w("$TAG - updateMessageOptions - end fail - add:$added - old:${message.options} - msgId:${message.msgId}");
    }
    return options != null;
  }

  ///*********************************************************************************///
  ///************************************ Handle *************************************///
  ///*********************************************************************************///

  Future<bool> isMessageReceived(MessageSchema message) async {
    MessageSchema? exists = await query(message.msgId);
    if (exists != null) return true;
    if (message.isTargetContact) {
      ContactSchema? _contact = await contactCommon.query(message.targetId, fetchWalletAddress: false);
      if (_contact == null) return false;
      Map<String, int> receivedMessages = _contact.receivedMessages;
      int? timeAt = receivedMessages[message.msgId];
      return timeAt != null;
    } else if (message.isTargetGroup) {
      PrivateGroupSchema? _group = await privateGroupCommon.queryGroup(message.targetId);
      if (_group == null) return false;
      Map<String, int> receivedMessages = _group.receivedMessages;
      int? timeAt = receivedMessages[message.msgId];
      return timeAt != null;
    }
    return false;
  }

  Future<bool> refreshTargetReceivedMessagesTag(String? targetId, int targetType) async {
    if (targetId == null || targetId.isEmpty) return false;
    if ((targetType != SessionType.CONTACT) && (targetType != SessionType.PRIVATE_GROUP)) return false;
    int nowAt = DateTime.now().millisecondsSinceEpoch;
    int gap = 365 * 24 * 60 * 60 * 1000; // 365d
    int minReceiveAt = nowAt - gap;
    Map<String, int>? receivedMessages;
    if (targetType == SessionType.CONTACT) {
      receivedMessages = (await contactCommon.query(targetId, fetchWalletAddress: false))?.receivedMessages;
    } else if (targetType == SessionType.PRIVATE_GROUP) {
      receivedMessages = (await privateGroupCommon.queryGroup(targetId))?.receivedMessages;
    }
    if (receivedMessages == null) return false;
    if (receivedMessages.isEmpty) {
      logger.d("$TAG - refreshTargetReceivedMessagesTag - receivedMessages is empty - receivedMessages:$receivedMessages - targetId:$targetId - targetType:$targetType");
      return true;
    }
    int startLen = receivedMessages.keys.length;
    List<String> delKeys = [];
    List<String> msgIdList = receivedMessages.keys.toList();
    for (var i = 0; i < msgIdList.length; i++) {
      String msgId = msgIdList[i];
      int? receiveAt = receivedMessages[msgId];
      if ((receiveAt == null) || (receiveAt <= minReceiveAt)) {
        delKeys.add(msgId);
      }
    }
    if (delKeys.isEmpty) {
      logger.d("$TAG - refreshTargetReceivedMessagesTag - delKeys is empty - receivedMessages:$receivedMessages - targetId:$targetId - targetType:$targetType");
      return true;
    }
    var data;
    if (targetType == SessionType.CONTACT) {
      data = await contactCommon.setReceivedMessages(targetId, {}, delKeys);
    } else if (targetType == SessionType.PRIVATE_GROUP) {
      data = await privateGroupCommon.setReceivedMessages(targetId, {}, delKeys);
    }
    if (data != null) {
      logger.i("$TAG - refreshTargetReceivedMessagesTag - success - count:${delKeys.length}/$startLen - delKeys:$delKeys - receivedMessages:$receivedMessages - targetId:$targetId - targetType:$targetType");
    } else {
      logger.w("$TAG - refreshTargetReceivedMessagesTag - fail - count:${delKeys.length}/$startLen - delKeys:$delKeys - receivedMessages:$receivedMessages - targetId:$targetId - targetType:$targetType");
    }
    return data != null;
  }

  Future<bool> onSessionDelete(String? targetId, int targetType) async {
    // received tags
    if ((targetType == SessionType.CONTACT) || (targetType == SessionType.PRIVATE_GROUP)) {
      int limit = 30;
      int gap = 30 * 24 * 60 * 60 * 1000; // 30d == clientMaxHoldTime
      int nowAt = DateTime.now().millisecondsSinceEpoch;
      int minSendAt = nowAt - gap;
      // query
      List<MessageSchema> messageList = [];
      List<int> statusList = [MessageStatus.Success, MessageStatus.Receipt, MessageStatus.Read];
      for (int i = 0; i < statusList.length; i++) {
        int status = statusList[i];
        for (int offset = 0; true; offset += limit) {
          List<MessageSchema> result = await MessageStorage.instance.queryListByTarget(targetId, targetType, isOutbound: false, status: status, offset: offset, limit: limit);
          List<MessageSchema> needTags = result.where((element) => element.sendAt > minSendAt).toList();
          messageList.addAll(needTags);
          if (result.length > needTags.length) break;
          if (result.length < limit) break;
        }
      }
      // tag
      dynamic target;
      if (targetType == SessionType.CONTACT) {
        target = await contactCommon.query(targetId, fetchWalletAddress: false);
      } else if (targetType == SessionType.PRIVATE_GROUP) {
        target = await privateGroupCommon.queryGroup(targetId);
      }
      Map<String, int> needTags = {};
      for (var i = 0; i < messageList.length; i++) {
        MessageSchema message = messageList[i];
        if ((targetType == SessionType.CONTACT) && (target is ContactSchema)) {
          if (!target.receivedMessages.containsKey(message.msgId)) {
            needTags.addAll({message.msgId: message.receiveAt ?? nowAt});
          }
        } else if ((targetType == SessionType.PRIVATE_GROUP) && (target is PrivateGroupSchema)) {
          if (!target.receivedMessages.containsKey(message.msgId)) {
            needTags.addAll({message.msgId: message.receiveAt ?? nowAt});
          }
        }
      }
      // target
      if (needTags.isNotEmpty) {
        if ((targetType == SessionType.CONTACT) && (target is ContactSchema)) {
          var data = await contactCommon.setReceivedMessages(targetId, needTags, []);
          if (data != null) {
            logger.i("$TAG - onSessionDelete - contact setReceivedMessages success - count:${needTags.length} - tage:$needTags - receivedMessages:${target.receivedMessages} - targetId:$targetType - targetId:$targetType - targetData:$data");
          } else {
            logger.w("$TAG - onSessionDelete - contact setReceivedMessages fail - count:${needTags.length} - tage:$needTags - receivedMessages:${target.receivedMessages} - targetId:$targetType - targetId:$targetType - targetData:$data");
          }
        } else if ((targetType == SessionType.PRIVATE_GROUP) && (target is PrivateGroupSchema)) {
          var data = await privateGroupCommon.setReceivedMessages(targetId, needTags, []);
          if (data != null) {
            logger.i("$TAG - onSessionDelete - privateGroup setReceivedMessages success - count:${needTags.length} - tage:$needTags - receivedMessages:${target.receivedMessages} - targetId:$targetType - targetId:$targetType - targetData:$data");
          } else {
            logger.w("$TAG - onSessionDelete - privateGroup setReceivedMessages fail - count:${needTags.length} - tage:$needTags - receivedMessages:${target.receivedMessages} - targetId:$targetType - targetId:$targetType - targetData:$data");
          }
        }
      }
    }
    // messages
    await MessageStorage.instance.deleteByTarget(targetId, targetType);
    // pieces
    await MessagePieceStorage.instance.deleteByTarget(targetId, targetType);
    return true;
  }

  Future<int> readOtherSideMessagesBySelf(String? targetId, int targetType) async {
    if (targetId == null || targetId.isEmpty) return 0;
    // query
    List<MessageSchema> unreadList = await queryAllByTargetOutboundStatus(targetId, targetType, false, MessageStatus.Success);
    unreadList.addAll(await queryAllByTargetOutboundStatus(targetId, targetType, false, MessageStatus.Receipt));
    // update
    List<String> msgIds = [];
    for (var i = 0; i < unreadList.length; i++) {
      MessageSchema element = unreadList[i];
      element = await updateMessageStatus(element, MessageStatus.Read);
      if (element.status == MessageStatus.Read) {
        msgIds.add(element.msgId);
      }
    }
    // send
    if (msgIds.isNotEmpty && (targetType == SessionType.CONTACT)) {
      chatOutCommon.sendRead(targetId, msgIds); // await
    }
    logger.d("$TAG - readOtherSideMessagesBySelf - count:${msgIds.length} - targetId:$targetId");
    return msgIds.length;
  }

  Future<int> correctOwnSideMessagesRead(String? targetId, int targetType, int? lastSendAt) async {
    if (targetId == null || targetId.isEmpty || lastSendAt == null || lastSendAt == 0) return 0;
    int readMinGap = 10 * 1000; // 10s
    // query
    List<MessageSchema> unReadList = await queryAllByTargetOutboundStatus(targetId, targetType, true, MessageStatus.Receipt);
    unReadList = unReadList.where((element) => element.sendAt <= (lastSendAt - readMinGap)).toList();
    if (unReadList.isEmpty) {
      logger.d("$TAG - correctOwnSideMessagesRead - empty - targetId:$targetId - targetType:$targetType - lastSendAt:$lastSendAt");
      return 0;
    }
    logger.i("$TAG - correctOwnSideMessagesRead - count:${unReadList.length} - targetId:$targetId - targetType:$targetType - lastSendAt:$lastSendAt");
    // update
    for (var i = 0; i < unReadList.length; i++) {
      MessageSchema element = unReadList[i];
      int? receiveAt = (element.receiveAt == null) ? DateTime.now().millisecondsSinceEpoch : element.receiveAt;
      logger.d("$TAG - correctOwnSideMessagesRead - receiveAt:$receiveAt - element:${element.toStringSimple()} - targetId:$targetId - targetType:$targetType - lastSendAt:$lastSendAt");
      await updateMessageStatus(element, MessageStatus.Read, receiveAt: receiveAt, notify: true);
    }
    return unReadList.length;
  }

  ///*********************************************************************************///
  ///************************************* Queue *************************************///
  ///*********************************************************************************///

  Future<MessageSchema> loadMessageSendQueue(MessageSchema message) async {
    if (!message.canQueue) return message;
    if (message.isTargetContact && !message.isTargetSelf) {
      await chatInCommon.waitReceiveQueue(message.targetId, "loadMessageSendQueue_");
      DeviceInfoSchema? device = await deviceInfoCommon.queryLatest(message.targetId); // just can latest
      if ((device != null) && DeviceInfoCommon.isMessageQueueEnable(device.platform, device.appVersion)) {
        message.queueId = await newContactMessageQueueId(message.targetId, device.deviceId, message.msgId);
        if (message.queueId > 0) {
          String? queueIds = await deviceInfoCommon.joinQueueIdsByAddressDeviceId(message.targetId, device.deviceId);
          if (queueIds != null) {
            message.options = MessageOptions.setFirstMessageQueueIds(message.options, queueIds);
            message.options = MessageOptions.setMessageQueueIds(message.options, queueIds);
          }
        } else {
          logger.w("$TAG - loadMessageSendQueue - new queueId fail - queueId:${message.queueId} - options:${message.options} - targetId:${message.targetId}");
        }
      } else {
        // device no support
      }
    } else {
      // nothing
    }
    return message;
  }

  Future<MessageSchema> loadMessageSendQueueAgain(MessageSchema message) async {
    if (!message.canQueue) return message;
    if (message.isTargetContact && !message.isTargetSelf) {
      await chatInCommon.waitReceiveQueue(message.targetId, "loadMessageSendQueueAgain_");
      DeviceInfoSchema? device = await deviceInfoCommon.queryLatest(message.targetId); // must be latest
      if ((device != null) && DeviceInfoCommon.isMessageQueueEnable(device.platform, device.appVersion)) {
        String? oldQueueIds = MessageOptions.getMessageQueueIds(message.options);
        if ((message.queueId <= 0) || (message.status == MessageStatus.Error)) {
          String newDeviceId = Settings.deviceId;
          int newQueueId = await newContactMessageQueueId(message.targetId, device.deviceId, message.msgId);
          if (newQueueId > 0) {
            bool success = await updateDeviceQueueId(message.msgId, newDeviceId, newQueueId);
            if (!success) return message;
            message.deviceId = newDeviceId;
            message.queueId = newQueueId;
          }
        }
        if (message.queueId > 0) {
          String? newQueueIds = await deviceInfoCommon.joinQueueIdsByAddressDeviceId(message.targetId, device.deviceId);
          logger.i("$TAG - loadMessageSendQueueAgain - re_new queueIds success - queueId:${message.queueId} - newQueueIds:$newQueueIds - oldQueueIds:$oldQueueIds - options:${message.options} - targetId:${message.targetId}");
          if (newQueueIds != null) message.options = MessageOptions.setMessageQueueIds(message.options, newQueueIds);
          await updateMessageOptions(message, message.options, notify: true);
        } else {
          logger.w("$TAG - loadMessageSendQueueAgain - re_new queueId fail - queueId:${message.queueId} - oldQueueIds:$oldQueueIds - options:${message.options} - targetId:${message.targetId}");
        }
      } else {
        // device no support
      }
    } else {
      // nothing
    }
    return message;
  }

  Future<int> newContactMessageQueueId(String? targetAddress, String? targetDeviceId, String? messageId) async {
    if ((targetAddress == null) || targetAddress.isEmpty) return 0;
    if ((targetDeviceId == null) || targetDeviceId.isEmpty) return 0; // filter old_version
    if ((messageId == null) || messageId.isEmpty) return 0;
    Function func = () async {
      DeviceInfoSchema? targetDevice = await deviceInfoCommon.query(targetAddress, targetDeviceId);
      if (targetDevice == null) return 0;
      String? queueIds = deviceInfoCommon.joinQueueIdsByDevice(targetDevice);
      logger.i("$TAG - newContactMessageQueueId - START - queueIds:$queueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId - messageId:$messageId");
      int nextQueueId = 0;
      // oldExists
      Map<int, String> sendingMessageQueueIds = targetDevice.sendingMessageQueueIds;
      if (sendingMessageQueueIds.isNotEmpty) {
        if (sendingMessageQueueIds.containsValue(messageId)) {
          sendingMessageQueueIds.forEach((key, value) {
            if (value == messageId) {
              logger.d("$TAG - newContactMessageQueueId - find in sending_ids - nextQueueId:$key - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
              nextQueueId = key;
            }
          });
        } else {
          List<int> keys = sendingMessageQueueIds.keys.toList();
          for (var i = 0; i < keys.length; i++) {
            int queueId = keys[i];
            String msgId = sendingMessageQueueIds[queueId]?.toString() ?? "";
            MessageSchema? msg = await query(msgId);
            if ((msg == null) || !msg.canQueue || !msg.isOutbound) {
              logger.w("$TAG - newContactMessageQueueId - replace wrong msg (wrong here) - nextQueueId:$queueId - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId - msg:${msg?.toStringSimple() ?? msgId}");
              nextQueueId = queueId;
              break;
            } else if (msg.status == MessageStatus.Error) {
              logger.d("$TAG - newContactMessageQueueId - replace status error - nextQueueId:$queueId - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId - msg:${msg.toStringSimple()}");
              nextQueueId = queueId;
              break;
            } else if (msg.status >= MessageStatus.Success) {
              logger.w("$TAG - newContactMessageQueueId - replace wrong status(wrong here) - nextQueueId:$queueId - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId - msg:${msg.toStringSimple()}");
              nextQueueId = queueId;
              break;
            } else {
              logger.i("$TAG - newContactMessageQueueId - replace nothing - msg:${msg.toStringSimple()} - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
            }
          }
        }
      }
      // newCreate
      int latestSendMessageQueueId = targetDevice.latestSendMessageQueueId;
      if (nextQueueId <= 0) {
        nextQueueId = latestSendMessageQueueId + 1;
        logger.d("$TAG - newContactMessageQueueId - increase queue_id - nextQueueId:$nextQueueId - newMsgId:$messageId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      }
      // update
      await deviceInfoCommon.setSendingMessageQueueIds(targetAddress, targetDeviceId, {nextQueueId: messageId}, []);
      if (nextQueueId > latestSendMessageQueueId) {
        await deviceInfoCommon.setLatestSendMessageQueueId(targetAddress, targetDeviceId, nextQueueId);
      }
      logger.i("$TAG - newContactMessageQueueId - END - nextQueueId:$nextQueueId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId - messageId:$messageId");
      return nextQueueId;
    };
    // queue
    _messageQueueIdQueues[targetAddress] = _messageQueueIdQueues[targetAddress] ?? ParallelQueue("message_queue_id_$targetAddress", onLog: (log, error) => error ? logger.w(log) : null);
    int? queueId = await _messageQueueIdQueues[targetAddress]?.add(() => func());
    return queueId ?? 0;
  }

  Future<bool> onContactMessageQueueSendSuccess(String? targetAddress, String? targetDeviceId, int queueId) async {
    if ((targetAddress == null) || targetAddress.isEmpty) return false;
    if ((targetDeviceId == null) || targetDeviceId.isEmpty) return false;
    if (queueId <= 0) return false;
    Function func = () async {
      DeviceInfoSchema? targetDevice = await deviceInfoCommon.query(targetAddress, targetDeviceId);
      if (targetDevice == null) return false;
      logger.i("$TAG - onContactMessageQueueSendSuccess - delete queueId from sending - queueId:$queueId - caches:${targetDevice.sendingMessageQueueIds} - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      return await deviceInfoCommon.setSendingMessageQueueIds(targetAddress, targetDeviceId, {}, [queueId]);
    };
    // queue
    _messageQueueIdQueues[targetAddress] = _messageQueueIdQueues[targetAddress] ?? ParallelQueue("message_queue_id_$targetAddress", onLog: (log, error) => error ? logger.w(log) : null);
    bool? success = await _messageQueueIdQueues[targetAddress]?.add(() => func());
    return success ?? false;
  }

  Future<bool> onContactMessageQueueReceive(MessageSchema message) async {
    if (!message.canQueue || (message.queueId <= 0)) return false;
    String targetAddress = message.sender;
    if (targetAddress.isEmpty) return false;
    Function func = () async {
      DeviceInfoSchema? targetDevice = await deviceInfoCommon.query(targetAddress, message.deviceId);
      if (targetDevice == null) return false;
      String? nativeQueueIds = deviceInfoCommon.joinQueueIdsByDevice(targetDevice);
      String? sideQueueIds = MessageOptions.getMessageQueueIds(message.options);
      String? receiveDeviceId = deviceInfoCommon.splitQueueIds(sideQueueIds)[3];
      if (receiveDeviceId?.trim() != Settings.deviceId.trim()) {
        logger.w("$TAG - onContactMessageQueueReceive - no target device - receiveDeviceId:$receiveDeviceId - nativeDeviceId:${Settings.deviceId} - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
        return false;
      }
      int receiveQueueId = message.queueId;
      int nativeQueueId = targetDevice.latestReceivedMessageQueueId;
      List<int> lostReceiveMessageQueueIds = targetDevice.lostReceiveMessageQueueIds;
      if (receiveQueueId > nativeQueueId) {
        logger.i("$TAG - onContactMessageQueueReceive - new higher - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
        bool success = await deviceInfoCommon.setLatestReceivedMessageQueueId(targetAddress, targetDevice.deviceId, receiveQueueId);
        if (success && ((receiveQueueId - nativeQueueId) > 1)) {
          List<int> lostPairs = List.generate(receiveQueueId - nativeQueueId - 1, (index) => nativeQueueId + index + 1);
          logger.i("$TAG - onContactMessageQueueReceive - new higher and add lostIds - lostPairs:$lostPairs - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
          await deviceInfoCommon.setLostReceiveMessageQueueIds(targetAddress, targetDevice.deviceId, lostPairs, []);
        }
      } else if (receiveQueueId < nativeQueueId) {
        if (lostReceiveMessageQueueIds.contains(receiveQueueId)) {
          logger.i("$TAG - onContactMessageQueueReceive - new lower and delete lostIds - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
          await deviceInfoCommon.setLostReceiveMessageQueueIds(targetAddress, targetDevice.deviceId, [], [receiveQueueId]);
        } else {
          logger.d("$TAG - onContactMessageQueueReceive - new lower and no lostIds - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
        }
      } else {
        logger.i("$TAG - onContactMessageQueueReceive - new == old - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
      }
      // clear too low queueId
      List<int> deleteQueueIds = lostReceiveMessageQueueIds.where((element) => element < (receiveQueueId - 100)).toList();
      if (deleteQueueIds.isNotEmpty) {
        logger.w("$TAG - onContactMessageQueueReceive - clear too low queueId - deleteIds:$deleteQueueIds - receiveQueueId:$receiveQueueId - nativeQueueId:$nativeQueueId - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds");
        await deviceInfoCommon.setLostReceiveMessageQueueIds(targetAddress, targetDevice.deviceId, [], deleteQueueIds);
      }
      return true;
    };
    // queue
    _messageQueueIdQueues[targetAddress] = _messageQueueIdQueues[targetAddress] ?? ParallelQueue("message_queue_id_$targetAddress", onLog: (log, error) => error ? logger.w(log) : null);
    bool? success = await _messageQueueIdQueues[targetAddress]?.add(() => func());
    return success ?? false;
  }

  Future syncContactMessages(String? targetAddress, String? targetDeviceId, int sideSendQueueId, int sideReceiveQueueId, List<int> sideLostQueueIds) async {
    if (targetAddress == null || targetAddress.isEmpty) return;
    if (targetDeviceId == null || targetDeviceId.isEmpty) return;
    // use latest params
    bool replace = true;
    String? oldParams = _syncMessageQueueParams["${targetAddress}_$targetDeviceId"];
    if (oldParams != null) {
      List splits = deviceInfoCommon.splitQueueIds(oldParams);
      if ((sideSendQueueId <= splits[0]) && (sideReceiveQueueId <= splits[1])) {
        replace = false;
      }
    }
    if (replace) {
      String? queueIds = deviceInfoCommon.joinQueueIds(sideSendQueueId, sideReceiveQueueId, sideLostQueueIds, "???");
      logger.d("$TAG - syncContactMessages - receive_queue params replace - newQueueIds:$queueIds - oldQueueIds:$oldParams - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      _syncMessageQueueParams["${targetAddress}_$targetDeviceId"] = queueIds;
    }
    // wait receive queue complete
    bool onComplete = await chatInCommon.waitReceiveQueue(targetAddress, "syncContactMessages_", duplicated: false);
    if (!onComplete) {
      logger.d("$TAG - syncContactMessages - receive_queue progress - params:$_syncMessageQueueParams - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      return;
    }
    logger.d("$TAG - syncContactMessages - receive_queue complete - params:$_syncMessageQueueParams - targetAddress:$targetAddress - sendQueueId:$sideSendQueueId");
    // use latest params
    String? queueIds = _syncMessageQueueParams["${targetAddress}_$targetDeviceId"];
    if (queueIds == null || queueIds.isEmpty) {
      logger.e("$TAG - syncContactMessages - params nil - queueIds:$queueIds - params:$_syncMessageQueueParams - targetAddress:$targetAddress - sendQueueId:$sideSendQueueId");
      return;
    }
    // check start
    List splits = deviceInfoCommon.splitQueueIds(queueIds);
    await _syncContactMessages(targetAddress, targetDeviceId, splits[0], splits[1], splits[2]);
  }

  Future<int> _syncContactMessages(String? targetAddress, String? targetDeviceId, int sideSendQueueId, int sideReceiveQueueId, List<int> sideLostQueueIds) async {
    if (targetAddress == null || targetAddress.isEmpty) return 0;
    if (targetDeviceId == null || targetDeviceId.isEmpty) return 0;
    // contact refresh
    DeviceInfoSchema? targetDevice = await deviceInfoCommon.query(targetAddress, targetDeviceId);
    if (targetDevice == null) return 0;
    String? sideQueueIds = deviceInfoCommon.joinQueueIds(sideSendQueueId, sideReceiveQueueId, sideLostQueueIds, targetDeviceId);
    String? nativeQueueIds = deviceInfoCommon.joinQueueIdsByDevice(targetDevice);
    logger.i("$TAG - _syncContactMessages - START - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    // sync update
    int nativeSendQueueId = targetDevice.latestSendMessageQueueId;
    int nativeReceiveQueueId = targetDevice.latestReceivedMessageQueueId;
    List<int> lostReceiveMessageQueueIds = targetDevice.lostReceiveMessageQueueIds;
    if (sideReceiveQueueId > nativeSendQueueId) {
      logger.w("$TAG - _syncContactMessages - need self to sync queue (update native send/receive_queueId) - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      await chatOutCommon.sendQueue(targetAddress, targetDeviceId); // must wait and before update
      await deviceInfoCommon.setLatestSendMessageQueueId(targetAddress, targetDeviceId, sideReceiveQueueId);
      if (sideSendQueueId > nativeReceiveQueueId) {
        await deviceInfoCommon.setLatestReceivedMessageQueueId(targetAddress, targetDeviceId, sideSendQueueId);
      }
      // sendingMessageQueueIds and lostReceiveMessageQueueIds will be correct auto
      return 0; // wait sendQueue reply
    }
    // sync request
    if ((sideSendQueueId > nativeReceiveQueueId) || lostReceiveMessageQueueIds.isNotEmpty) {
      logger.i("$TAG - _syncContactMessages - need side to resend lost - sideSendQueueId:$sideSendQueueId - nativeReceiveQueueId:$nativeReceiveQueueId - lostReceiveMessageQueueIds:$lostReceiveMessageQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      await chatOutCommon.sendQueue(targetAddress, targetDeviceId);
    } else if (sideSendQueueId < nativeReceiveQueueId) {
      logger.w("$TAG - _syncContactMessages - need side to sync queue - sideSendQueueId:$sideSendQueueId - nativeReceiveQueueId:$nativeReceiveQueueId - lostReceiveMessageQueueIds:$lostReceiveMessageQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      await chatOutCommon.sendQueue(targetAddress, targetDeviceId);
      return 0; // wait sendQueue reply
    } else {
      logger.d("$TAG - _syncContactMessages - queueIds no wrong (side==native) - sideSendQueueId:$sideSendQueueId - nativeReceiveQueueId:$nativeReceiveQueueId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    }
    // noAck
    List<MessageSchema> noAckList = await queryAllNoACKByTarget(targetAddress, SessionType.CONTACT);
    noAckList.removeWhere((element) => !element.canQueue);
    // queueIds
    List<int> resendQueueIds = sideLostQueueIds;
    if (sideReceiveQueueId < nativeSendQueueId) {
      List<int> newLost = List.generate(nativeSendQueueId - sideReceiveQueueId, (index) => sideReceiveQueueId + index + 1);
      logger.i("$TAG - _syncContactMessages - resendQueueIds add latest msg - newLost:$newLost - sideReceiveQueueId:$sideReceiveQueueId - nativeSendQueueId:$nativeSendQueueId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      resendQueueIds.addAll(newLost);
    } else {
      logger.d("$TAG - _syncContactMessages - resendQueueIds ok latest msg - sideReceiveQueueId:$sideReceiveQueueId - nativeSendQueueId:$nativeSendQueueId - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    }
    if (resendQueueIds.isEmpty) {
      logger.d("$TAG - _syncContactMessages - resendQueueIds is empty - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      for (var i = 0; i < noAckList.length; i++) {
        MessageSchema noAck = noAckList[i];
        logger.i("$TAG - _syncContactMessages - noAck status update - message:$noAck - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
        await updateMessageStatus(noAck, MessageStatus.Receipt, receiveAt: DateTime.now().millisecondsSinceEpoch);
      }
      return 0;
    }
    logger.i("$TAG - _syncContactMessages - resendQueueIds no empty - count:${resendQueueIds.length} - resendQueueIds:$resendQueueIds - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    // messages
    List<MessageSchema> resendMsgList = [];
    final limit = 3;
    int statusSendingCount = 0;
    int statusErrorCount = 0;
    for (var i = 0; i < resendQueueIds.length; i++) {
      int queueId = resendQueueIds[i];
      for (int offset = 0; true; offset += limit) {
        List<MessageSchema> result = await queryListByTargetDeviceQueueId(targetAddress, SessionType.CONTACT, Settings.deviceId, queueId, offset: offset, limit: limit);
        MessageSchema? resendMsg;
        bool isStatusSending = false;
        bool isStatusError = false;
        for (var j = 0; j < result.length; j++) {
          MessageSchema message = result[j];
          String? queueIds = MessageOptions.getMessageQueueIds(message.options);
          List splits = deviceInfoCommon.splitQueueIds(queueIds);
          bool isSameDevice = (queueIds != null) && (splits[3].toString().trim() == targetDeviceId.trim());
          if (message.canReceipt && message.isOutbound && isSameDevice && (message.status >= MessageStatus.Success)) {
            logger.i("$TAG - _syncContactMessages - resend messages add - queueId:$queueId - message:$message - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
            resendMsg = message;
            break;
          }
          isStatusSending = (message.status == MessageStatus.Sending) || isStatusSending;
          isStatusError = (message.status == MessageStatus.Error) || isStatusError;
        }
        if (resendMsg != null) {
          resendMsgList.add(resendMsg);
          break;
        } else if (result.length < limit) {
          if (isStatusSending) {
            logger.d("$TAG - _syncContactMessages - resend message no find (status sending) - queueId:$queueId - msgs:${result.length} - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
            statusSendingCount++;
          } else if (isStatusError) {
            logger.d("$TAG - _syncContactMessages - resend message no find (status error) - queueId:$queueId - msgs:${result.length} - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
            statusErrorCount++;
          } else {
            logger.w("$TAG - _syncContactMessages - resend message no find - queueId:$queueId - msgs:${result.length} - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
          }
          break;
        }
      }
    }
    if (resendMsgList.isEmpty) {
      if (resendMsgList.length <= (statusSendingCount + statusErrorCount)) {
        logger.i("$TAG - _syncContactMessages - resendMessages is empty (status ok) - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      } else {
        logger.w("$TAG - _syncContactMessages - resendMessages is empty - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
      }
      return 0;
    }
    logger.i("$TAG - _syncContactMessages - resendMessages no empty - count:${resendMsgList.length}/${resendQueueIds.length} - sideQueueIds:$sideQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    // ack check (maybe other device queue)
    bool noAckAdded = true;
    for (var i = 0; i < noAckList.length; i++) {
      MessageSchema noAck = noAckList[i];
      if (resendMsgList.indexWhere((element) => noAck.msgId == element.msgId) < 0) {
        logger.i("$TAG - _syncContactMessages - noAck add ok - message:$noAck - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
        noAckAdded = false;
        resendMsgList.add(noAck);
      }
    }
    if (noAckAdded) {
      logger.d("$TAG - _syncContactMessages - noAck add none - count:${resendMsgList.length}/${resendQueueIds.length} - resendQueueIds:$resendQueueIds - sideQueueIds:$sideQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    }
    // resend
    int successCount = 0;
    for (var i = 0; i < resendMsgList.length; i++) {
      MessageSchema message = resendMsgList[i];
      int gap = Settings.gapMessageQueueResendMs * ((message.contentType == MessageContentType.ipfs) ? 3 : (message.isContentFile ? 2 : 1));
      var data = await chatOutCommon.resend(message.msgId, mute: true, muteGap: gap);
      if (data != null) successCount++;
    }
    logger.i("$TAG - _syncContactMessages - END - count:$successCount/${resendMsgList.length} - sideQueueIds:$sideQueueIds - nativeQueueIds:$nativeQueueIds - targetAddress:$targetAddress - targetDeviceId:$targetDeviceId");
    return successCount;
  }

  // SUPPORT:START
  Future<int> checkMsgStatus(String? targetId, {int filterSec = 5}) async {
    if (!(await clientCommon.checkClientOk("checkMsgStatus"))) return 0;
    if (targetId == null || targetId.isEmpty) return 0;
    // device
    DeviceInfoSchema? device = await deviceInfoCommon.queryLatest(targetId);
    if ((device?.appVersion ?? 281) > 280) {
      logger.d("$TAG - checkMsgStatus - disable with high version - version:${device?.appVersion}");
      return 0;
    }
    // wait receive queue complete
    bool onComplete = await chatInCommon.waitReceiveQueue(targetId, "checkMsgStatus_", duplicated: false);
    if (!onComplete) {
      logger.d("$TAG - checkMsgStatus - receive_queue progress - targetId:$targetId");
      return 0;
    }
    await Future.delayed(Duration(milliseconds: 500));
    // noAck
    int limit = 20;
    int maxCount = 100;
    List<MessageSchema> messages = [];
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> result = await MessageStorage.instance.queryListByTarget(
        targetId,
        SessionType.CONTACT,
        isOutbound: true,
        status: MessageStatus.Success,
        offset: offset,
        limit: limit,
      );
      messages.addAll(result.where((element) => element.canReceipt).toList());
      if (result.length < limit) break;
      if (messages.length >= maxCount) break;
    }
    if (messages.isEmpty) {
      logger.d("$TAG - checkMsgStatus - OK OK OK - targetId:$targetId");
      return 0;
    }
    // filter
    messages = messages.where((element) {
      int msgSendAt = MessageOptions.getSendSuccessAt(element.options) ?? DateTime.now().millisecondsSinceEpoch;
      int between = DateTime.now().millisecondsSinceEpoch - msgSendAt;
      int filter = filterSec * ((element.contentType == MessageContentType.ipfs) ? 3 : (element.isContentFile ? 2 : 1));
      if (between < (filter * 1000)) {
        logger.d("$TAG - checkMsgStatus - sendAt justNow - targetId:$targetId - message:$element");
        return false;
      }
      return true;
    }).toList();
    if (messages.isEmpty) {
      logger.d("$TAG - checkMsgStatus - OK OK OK - targetId:$targetId");
      return 0;
    }
    logger.i("$TAG - checkMsgStatus - resend - len:${messages.length} - targetId:$targetId");
    // resend
    List<String> msgIds = [];
    messages.forEach((element) {
      if (element.msgId.isNotEmpty) msgIds.add(element.msgId);
    });
    chatOutCommon.sendMsgStatus(targetId, true, msgIds); // await
    return msgIds.length;
  }
// SUPPORT:END
}
