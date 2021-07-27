import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nkn_sdk_flutter/client.dart';
import 'package:nmobile/common/client/client.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/push/send_push.dart';
import 'package:nmobile/generated/l10n.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/native/common.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/subscriber.dart';
import 'package:nmobile/schema/topic.dart';
import 'package:nmobile/storages/message.dart';
import 'package:nmobile/utils/format.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/utils.dart';
import 'package:uuid/uuid.dart';

import '../locator.dart';

class ChatOutCommon with Tag {
  // piece
  static const int piecesParity = 3;
  static const int prePieceLength = 1024 * 6;
  static const int minPiecesTotal = 2 * piecesParity; // parity >= 2
  static const int maxPiecesTotal = 10 * piecesParity; // parity <= 10

  // ignore: close_sinks
  StreamController<MessageSchema> _onSavedController = StreamController<MessageSchema>.broadcast();
  StreamSink<MessageSchema> get _onSavedSink => _onSavedController.sink;
  Stream<MessageSchema> get onSavedStream => _onSavedController.stream.distinct((prev, next) => prev.msgId == next.msgId);

  // ignore: close_sinks
  StreamController<Map<String, dynamic>> _onPieceOutController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSink<Map<String, dynamic>> get _onPieceOutSink => _onPieceOutController.sink;
  Stream<Map<String, dynamic>> get onPieceOutStream => _onPieceOutController.stream.distinct((prev, next) => (next['msg_id'] == prev['msg_id']) && (next['percent'] < prev['percent']));

  MessageStorage _messageStorage = MessageStorage();

  ChatOutCommon();

  // NO DB NO display NO topic (1 to 1)
  Future sendReceipt(MessageSchema received, {int tryCount = 1}) async {
    if (received.from.isEmpty || received.isTopic) return;
    if (tryCount > 3) return;
    try {
      String data = MessageData.getReceipt(received.msgId);
      await chatCommon.clientSendData(received.from, data);
      logger.d("$TAG - sendReceipt - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendReceipt - fail - tryCount:$tryCount - received:$received");
      await Future.delayed(Duration(seconds: 2), () {
        return sendReceipt(received, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO display (1 to 1)
  Future sendContactRequest(ContactSchema? target, String requestType, {int tryCount = 1}) async {
    if (target == null || target.clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    try {
      int updateAt = DateTime.now().millisecondsSinceEpoch;
      String data = MessageData.getContactRequest(requestType, target.profileVersion, updateAt);
      await chatCommon.clientSendData(target.clientAddress, data);
      logger.d("$TAG - sendContactRequest - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendContactRequest - fail - tryCount:$tryCount - requestType:$requestType - target:$target");
      await Future.delayed(Duration(seconds: 2), () {
        return sendContactRequest(target, requestType, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO display (1 to 1)
  Future sendContactResponse(ContactSchema? target, String requestType, {ContactSchema? me, int tryCount = 1}) async {
    if (target == null || target.clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    ContactSchema? _me = me ?? await contactCommon.getMe();
    try {
      int updateAt = DateTime.now().millisecondsSinceEpoch;
      String data;
      if (requestType == RequestType.header) {
        data = MessageData.getContactResponseHeader(_me?.profileVersion, updateAt);
      } else {
        data = await MessageData.getContactResponseFull(_me?.firstName, _me?.lastName, _me?.avatar, _me?.profileVersion, updateAt);
      }
      await chatCommon.clientSendData(target.clientAddress, data);
      logger.d("$TAG - sendContactResponse - success - requestType:$requestType - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendContactResponse - fail - tryCount:$tryCount - requestType:$requestType");
      await Future.delayed(Duration(seconds: 2), () {
        return sendContactResponse(target, requestType, me: _me, tryCount: ++tryCount);
      });
    }
  }

  // NO topic (1 to 1)
  Future sendContactOptionsBurn(String? clientAddress, int deleteSeconds, int updateAt, {int tryCount = 1}) async {
    if (clientCommon.address == null || clientCommon.address!.isEmpty || clientAddress == null || clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    try {
      MessageSchema send = MessageSchema.fromSend(
        Uuid().v4(),
        clientCommon.address!,
        MessageContentType.contactOptions,
        to: clientAddress,
        deleteAfterSeconds: deleteSeconds,
        burningUpdateAt: updateAt,
      );
      send.content = MessageData.getContactOptionsBurn(send); // same with receive and old version
      await _sendAndDisplay(send, send.content);
      logger.d("$TAG - sendContactOptionsBurn - success - data:${send.content}");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendContactOptionsBurn - fail - tryCount:$tryCount - clientAddress:$clientAddress - deleteSeconds:$deleteSeconds");
      await Future.delayed(Duration(seconds: 2), () {
        return sendContactOptionsBurn(clientAddress, deleteSeconds, updateAt, tryCount: ++tryCount);
      });
    }
  }

  // NO topic (1 to 1)
  Future sendContactOptionsToken(String? clientAddress, String deviceToken, {int tryCount = 1}) async {
    if (clientCommon.address == null || clientCommon.address!.isEmpty || clientAddress == null || clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    try {
      MessageSchema send = MessageSchema.fromSend(
        Uuid().v4(),
        clientCommon.address!,
        MessageContentType.contactOptions,
        to: clientAddress,
      );
      send = MessageOptions.setDeviceToken(send, deviceToken);
      send.content = MessageData.getContactOptionsToken(send); // same with receive and old version
      await _sendAndDisplay(send, send.content);
      logger.d("$TAG - sendContactOptionsToken - success - data:${send.content}");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendContactOptionsToken - fail - tryCount:$tryCount - clientAddress:$clientAddress - deviceToken:$deviceToken");
      await Future.delayed(Duration(seconds: 2), () {
        return sendContactOptionsToken(clientAddress, deviceToken, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO display (1 to 1)
  Future sendDeviceRequest(String? clientAddress, {int tryCount = 1}) async {
    if (clientAddress == null || clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    try {
      String data = MessageData.getDeviceRequest();
      await chatCommon.clientSendData(clientAddress, data);
      logger.d("$TAG - sendDeviceRequest - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendDeviceRequest - fail - tryCount:$tryCount - clientAddress:$clientAddress");
      await Future.delayed(Duration(seconds: 2), () {
        return sendDeviceRequest(clientAddress, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO display (1 to 1)
  Future sendDeviceInfo(String? clientAddress, {int tryCount = 1}) async {
    if (clientAddress == null || clientAddress.isEmpty) return;
    if (tryCount > 3) return;
    try {
      String data = MessageData.getDeviceInfo();
      await chatCommon.clientSendData(clientAddress, data);
      logger.d("$TAG - sendDeviceInfo - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendDeviceInfo - fail - tryCount:$tryCount - clientAddress:$clientAddress");
      await Future.delayed(Duration(seconds: 2), () {
        return sendDeviceInfo(clientAddress, tryCount: ++tryCount);
      });
    }
  }

  Future<MessageSchema?> sendText(String? content, {ContactSchema? contact, TopicSchema? topic}) async {
    if ((contact?.clientAddress == null || contact?.clientAddress.isEmpty == true) && (topic?.topic == null || topic?.topic.isEmpty == true)) return null;
    if (content == null || content.isEmpty) return null;
    if (clientCommon.status != ClientConnectStatus.connected || clientCommon.address == null || clientCommon.address!.isEmpty) {
      // Toast.show(S.of(Global.appContext).failure); // TODO:GG locale
      return null;
    }
    MessageSchema message = MessageSchema.fromSend(
      Uuid().v4(),
      clientCommon.address!,
      MessageContentType.text,
      to: contact?.clientAddress,
      topic: topic?.topic,
      content: content,
      deleteAfterSeconds: contact?.options?.deleteAfterSeconds,
      burningUpdateAt: contact?.options?.updateBurnAfterAt,
    );
    String data = MessageData.getText(message);
    return _sendAndDisplay(message, data);
  }

  Future<MessageSchema?> sendImage(File? content, {ContactSchema? contact, TopicSchema? topic}) async {
    if ((contact?.clientAddress == null || contact?.clientAddress.isEmpty == true) && (topic?.topic == null || topic?.topic.isEmpty == true)) return null;
    if (content == null || (!await content.exists())) return null;
    if (clientCommon.status != ClientConnectStatus.connected || clientCommon.address == null || clientCommon.address!.isEmpty) {
      // Toast.show(S.of(Global.appContext).failure); // TODO:GG locale
      return null;
    }
    DeviceInfoSchema? deviceInfo = await deviceInfoCommon.queryLatest(contact?.clientAddress);
    String contentType = deviceInfoCommon.isMsgImageEnable(deviceInfo?.platform, deviceInfo?.appVersion) ? MessageContentType.image : MessageContentType.media;
    MessageSchema message = MessageSchema.fromSend(
      Uuid().v4(),
      clientCommon.address!,
      contentType,
      to: contact?.clientAddress,
      topic: topic?.topic,
      content: content,
      deleteAfterSeconds: contact?.options?.deleteAfterSeconds,
      burningUpdateAt: contact?.options?.updateBurnAfterAt,
    );
    String? data = await MessageData.getImage(message);
    return _sendAndDisplay(message, data, deviceInfo: deviceInfo);
  }

  Future<MessageSchema?> sendAudio(File? content, double? durationS, {ContactSchema? contact, TopicSchema? topic}) async {
    if ((contact?.clientAddress == null || contact?.clientAddress.isEmpty == true) && (topic?.topic == null || topic?.topic.isEmpty == true)) return null;
    if (content == null || (!await content.exists())) return null;
    if (clientCommon.status != ClientConnectStatus.connected || clientCommon.address == null || clientCommon.address!.isEmpty) {
      // Toast.show(S.of(Global.appContext).failure); // TODO:GG locale
      return null;
    }
    MessageSchema message = MessageSchema.fromSend(
      Uuid().v4(),
      clientCommon.address!,
      MessageContentType.audio,
      to: contact?.clientAddress,
      topic: topic?.topic,
      content: content,
      audioDurationS: durationS,
      deleteAfterSeconds: contact?.options?.deleteAfterSeconds,
      burningUpdateAt: contact?.options?.updateBurnAfterAt,
    );
    String? data = await MessageData.getAudio(message);
    return _sendAndDisplay(message, data);
  }

  // NO DB NO display
  Future<MessageSchema?> sendPiece(MessageSchema message, {int tryCount = 1}) async {
    if (tryCount > 3) return null;
    try {
      DateTime timeNow = DateTime.now();
      await Future.delayed(Duration(milliseconds: (message.sendTime ?? timeNow).millisecondsSinceEpoch - timeNow.millisecondsSinceEpoch));
      String data = MessageData.getPiece(message);
      if (message.isTopic) {
        OnMessage? onResult = await chatCommon.clientPublishData(genTopicHash(message.topic!), data); // TODO:GG topic send
        message.pid = onResult?.messageId;
      } else if (message.to != null) {
        OnMessage? onResult = await chatCommon.clientSendData(message.to, data);
        message.pid = onResult?.messageId;
      }
      // logger.d("$TAG - sendPiece - success - index:${schema.index} - total:${schema.total} - time:${timeNow.millisecondsSinceEpoch} - message:$message - data:$data");
      double percent = (message.index ?? 0) / (message.total ?? 1);
      _onPieceOutSink.add({"msg_id": message.msgId, "percent": percent});
      return message;
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendPiece - fail - tryCount:$tryCount - message:$message");
      return await Future.delayed(Duration(seconds: 2), () {
        return sendPiece(message, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO single
  Future sendTopicSubscribe(String? topic, {int tryCount = 1}) async {
    if (clientCommon.address == null || clientCommon.address!.isEmpty || topic == null || topic.isEmpty) return;
    if (tryCount > 3) return;
    try {
      MessageSchema send = MessageSchema.fromSend(
        Uuid().v4(),
        clientCommon.address!,
        MessageContentType.topicSubscribe,
        topic: topic,
      );
      String data = MessageData.getTopicSubscribe(send);
      await _sendAndDisplay(send, data);
      logger.d("$TAG - sendTopicSubscribe - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendTopicSubscribe - fail - tryCount:$tryCount - topic:$topic");
      await Future.delayed(Duration(seconds: 2), () {
        return sendTopicSubscribe(topic, tryCount: ++tryCount);
      });
    }
  }

  // NO DB NO single
  Future sendTopicUnSubscribe(String? topic, {int tryCount = 1}) async {
    if (clientCommon.address == null || clientCommon.address!.isEmpty || topic == null || topic.isEmpty) return;
    if (tryCount > 3) return;
    try {
      String data = MessageData.getTopicUnSubscribe(topic);
      await chatCommon.clientPublishData(genTopicHash(topic), data); // TODO:GG topic send
      logger.d("$TAG - sendTopicUnSubscribe - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendTopicUnSubscribe - fail - tryCount:$tryCount - topic:$topic");
      await Future.delayed(Duration(seconds: 2), () {
        return sendTopicUnSubscribe(topic, tryCount: ++tryCount);
      });
    }
  }

  // NO topic (1 to 1)
  Future<MessageSchema?> sendTopicInvitee(String? clientAddress, String? topic) async {
    if (clientAddress == null || clientAddress.isEmpty || topic == null || topic.isEmpty) return null;
    if (clientCommon.status != ClientConnectStatus.connected || clientCommon.address == null || clientCommon.address!.isEmpty) {
      // Toast.show(S.of(Global.appContext).failure); // TODO:GG locale
      return null;
    }
    MessageSchema message = MessageSchema.fromSend(
      Uuid().v4(),
      clientCommon.address!,
      MessageContentType.topicInvitation,
      to: clientAddress,
      content: topic,
    );
    String data = MessageData.getTopicInvitee(message);
    return _sendAndDisplay(message, data);
  }

  // NO DB NO single
  Future sendTopicKickOut(String? topic, String? targetAddress, {int tryCount = 1}) async {
    if (topic == null || topic.isEmpty || targetAddress == null || targetAddress.isEmpty || clientCommon.address == null || clientCommon.address!.isEmpty) return null;
    if (tryCount > 3) return;
    try {
      String data = MessageData.getTopicKickOut(topic, targetAddress);
      await chatCommon.clientPublishData(genTopicHash(topic), data); // TODO:GG topic send
      logger.d("$TAG - sendTopicKickOut - success - data:$data");
    } catch (e) {
      handleError(e);
      logger.w("$TAG - sendTopicKickOut - fail - tryCount:$tryCount - topic:$topic");
      await Future.delayed(Duration(seconds: 2), () {
        return sendTopicKickOut(topic, targetAddress, tryCount: ++tryCount);
      });
    }
  }

  Future<MessageSchema?> resend(
    MessageSchema? message, {
    ContactSchema? contact,
    DeviceInfoSchema? deviceInfo,
    TopicSchema? topic,
  }) async {
    if (message == null) return null;
    message = chatCommon.updateMessageStatus(message, MessageStatus.Sending);
    switch (message.contentType) {
      case MessageContentType.text:
      case MessageContentType.textExtension:
        return await _sendAndDisplay(
          message,
          MessageData.getText(message),
          contact: contact,
          topic: topic,
          deviceInfo: deviceInfo,
          resend: true,
        );
      case MessageContentType.media:
      case MessageContentType.image:
      case MessageContentType.nknImage:
        return await _sendAndDisplay(
          message,
          await MessageData.getImage(message),
          contact: contact,
          topic: topic,
          deviceInfo: deviceInfo,
          resend: true,
        );
      case MessageContentType.audio:
        return await _sendAndDisplay(
          message,
          await MessageData.getAudio(message),
          contact: contact,
          topic: topic,
          deviceInfo: deviceInfo,
          resend: true,
        );
    }
    return message;
  }

  Future<MessageSchema?> _sendAndDisplay(
    MessageSchema? message,
    String? msgData, {
    ContactSchema? contact,
    DeviceInfoSchema? deviceInfo,
    TopicSchema? topic,
    bool resend = false,
  }) async {
    if (message == null || msgData == null) return null;
    // DB
    if (!resend) {
      message = await _messageStorage.insert(message);
    } else {
      message.sendTime = DateTime.now();
      _messageStorage.updateSendTime(message.msgId, message.sendTime); // await
    }
    if (message == null) return null;
    // display
    _onSavedSink.add(message); // resend already delete fail item in listview
    // contact
    contact = contact ?? await chatCommon.contactHandle(message);
    DeviceInfoSchema? _deviceInfo = deviceInfo ?? await chatCommon.deviceInfoHandle(message, contact);
    // topic
    topic = topic ?? await chatCommon.topicHandle(message);
    chatCommon.subscriberHandle(message, topic); // await
    // session
    chatCommon.sessionHandle(message); // await
    // SDK
    Uint8List? pid;
    try {
      if (message.isTopic) {
        pid = await _sendWithTopic(topic, message, msgData);
        logger.d("$TAG - _sendAndDisplay - to_topic - to:${message.topic} - pid:$pid");
      } else if (message.to?.isNotEmpty == true) {
        pid = await _sendByPiecesIfNeed(message, _deviceInfo);
        if (pid == null || pid.isEmpty) {
          pid = (await chatCommon.clientSendData(message.to!, msgData))?.messageId;
          logger.d("$TAG - _sendAndDisplay - to_contact - to:${message.to} - pid:$pid - deviceInfo:$_deviceInfo");
        } else {
          logger.d("$TAG - _sendAndDisplay - to_contact_pieces - to:${message.to} - pid:$pid - deviceInfo:$_deviceInfo");
        }
      } else {
        logger.e("$TAG - _sendAndDisplay - to_null - message:$message");
      }
    } catch (e) {
      handleError(e);
    }
    // fail
    if (pid == null || pid.isEmpty) {
      logger.w("$TAG - _sendAndDisplay - pid = null - message:$message");
      message = chatCommon.updateMessageStatus(message, MessageStatus.SendFail, notify: true);
      return message;
    }
    // pid
    message.pid = pid;
    _messageStorage.updatePid(message.msgId, message.pid); // await
    // status
    message = chatCommon.updateMessageStatus(message, MessageStatus.SendSuccess, notify: true);
    // notification
    _sendPush(message, contact, topic); // await
    return message;
  }

  Future<Uint8List?> _sendWithTopic(TopicSchema? topic, MessageSchema? message, String? msgData) async {
    if (message == null || msgData == null) return null;
    // topic
    if (topic == null) {
      logger.w("$TAG - _sendWithTopic - topic == null - message:$message - msgData:$msgData");
      OnMessage? onResult = await chatCommon.clientPublishData(genTopicHash(message.topic!), msgData); // noCheckPermission
      return onResult?.messageId;
    }
    // subscribers
    List<SubscriberSchema> _subscribers = [];
    if ((DateTime.now().millisecondsSinceEpoch - clientCommon.signInAt) <= 20 * 1000) {
      List<SubscriberSchema> result = await subscriberCommon.mergeSubscribersAndPermissionsFromNode(topic.topic, meta: topic.isPrivate);
      _subscribers = result.where((element) => element.status == SubscriberStatus.Subscribed).toList();
      logger.d("$TAG - _sendWithTopic - _subscribers from node - counts:${_subscribers.length} - topic:$topic - message:$message - msgData:$msgData");
    } else {
      _subscribers = await subscriberCommon.queryListByTopic(topic.topic, status: SubscriberStatus.Subscribed);
      logger.d("$TAG - _sendWithTopic - _subscribers from DB - counts:${_subscribers.length} - topic:$topic - message:$message - msgData:$msgData");
    }
    if (_subscribers.isEmpty) {
      logger.w("$TAG - _sendWithTopic - _subscribers is empty - topic:$topic - message:$message - msgData:$msgData");
      return null;
    }
    // sendData
    Uint8List? pid;
    List<Future> futures = [];
    _subscribers.forEach((SubscriberSchema subscriber) {
      futures.add(deviceInfoCommon.queryLatest(subscriber.clientAddress).then((DeviceInfoSchema? deviceInfo) {
        return _sendByPiecesIfNeed(message, deviceInfo);
      }).then((Uint8List? _pid) {
        if (_pid == null || _pid.isEmpty) {
          logger.d("$TAG - _sendWithTopic - to_subscriber - to:${subscriber.clientAddress} - subscriber:$subscriber");
          return chatCommon.clientSendData(message.to!, msgData);
        } else {
          logger.d("$TAG - _sendWithTopic - to_subscriber_pieces - to:${subscriber.clientAddress} - subscriber:$subscriber - pid:$_pid");
          return Future.value(OnMessage(messageId: _pid, data: null, src: null, type: null, encrypted: null));
        }
      }).then((OnMessage? onResult) {
        var _pid = onResult?.messageId;
        if ((_pid != null) && (pid == null)) {
          logger.d("$TAG - _sendWithTopic - find_pid_first - pid:$_pid - subscriber:$subscriber");
          pid = _pid;
        }
        if ((_pid != null) && (subscriber.clientAddress == clientCommon.address)) {
          logger.d("$TAG - _sendWithTopic - find_pid_last - pid:$_pid - subscriber:$subscriber");
          pid = _pid;
        }
      }));
    });
    await Future.wait(futures);
    return pid;
  }

  _sendPush(MessageSchema message, ContactSchema? contact, TopicSchema? topic) async {
    if (!message.canDisplayAndRead) return;
    if (topic != null) {
      // TODO:GG topic get all subscribe token and list.send
      return;
    }
    if (contact?.deviceToken == null || contact!.deviceToken!.isEmpty) return;

    S localizations = S.of(Global.appContext);

    String title = localizations.new_message;
    // if (topic != null) {
    //   title = '[${topic.topicShort}] ${contact?.displayName}';
    // } else if (contact != null) {
    //   title = contact.displayName;
    // }

    String content = localizations.you_have_new_message;
    // switch (message.contentType) {
    //   case ContentType.text:
    //   case ContentType.textExtension:
    //     content = message.content;
    //     break;
    //   case ContentType.media:
    //   case ContentType.image:
    //   case ContentType.nknImage:
    //     content = '[${localizations.image}]';
    //     break;
    //   case ContentType.audio:
    //     content = '[${localizations.audio}]';
    //     break;
    //   case ContentType.topicSubscribe:
    //   case ContentType.topicUnsubscribe:
    //   case ContentType.topicInvitation:
    //     break;
    // }

    await SendPush.send(contact.deviceToken!, title, content);
  }

  Future<Uint8List?> _sendByPiecesIfNeed(MessageSchema message, DeviceInfoSchema? deviceInfo) async {
    if (!deviceInfoCommon.isMsgPieceEnable(deviceInfo?.platform, deviceInfo?.appVersion)) return null;
    List results = await _convert2Pieces(message);
    if (results.isEmpty) return null;
    String dataBytesString = results[0];
    int bytesLength = results[1];
    int total = results[2];
    int parity = results[3];

    // dataList.size = (total + parity)
    List<Object?> dataList = await Common.splitPieces(dataBytesString, total, parity);
    if (dataList.isEmpty) return null;

    List<Future<MessageSchema?>> futures = <Future<MessageSchema?>>[];
    DateTime dataNow = DateTime.now();
    for (int index = 0; index < dataList.length; index++) {
      Uint8List? data = dataList[index] as Uint8List?;
      if (data == null || data.isEmpty) continue;
      MessageSchema send = MessageSchema.fromSend(
        message.msgId,
        message.from,
        MessageContentType.piece,
        to: message.to,
        topic: message.topic,
        content: base64Encode(data),
        options: message.options,
        parentType: message.contentType,
        bytesLength: bytesLength,
        total: total,
        parity: parity,
        index: index,
      );
      send.sendTime = dataNow.add(Duration(milliseconds: index * 50)); // wait 50ms
      futures.add(sendPiece(send));
    }
    logger.d("$TAG - _sendByPiecesIfNeed:START - total:$total - parity:$parity - bytesLength:${formatFlowSize(bytesLength.toDouble(), unitArr: ['B', 'KB', 'MB', 'GB'])}");
    List<MessageSchema?> returnList = await Future.wait(futures);
    returnList.sort((prev, next) => (prev?.index ?? maxPiecesTotal).compareTo((next?.index ?? maxPiecesTotal)));

    List<MessageSchema?> successList = returnList.where((element) => element != null).toList();
    if (successList.length < total) {
      logger.w("$TAG - _sendByPiecesIfNeed:FAIL - count:${successList.length}");
      return null;
    }
    logger.d("$TAG - _sendByPiecesIfNeed:SUCCESS - count:${successList.length}");

    MessageSchema? firstSuccess = returnList.firstWhere((element) => element?.pid != null);
    return firstSuccess?.pid;
  }

  Future<List<dynamic>> _convert2Pieces(MessageSchema message) async {
    if (!(message.content is File?)) return [];
    File? file = message.content as File?;
    if (file == null || !file.existsSync()) return [];
    int length = await file.length();
    if (length <= prePieceLength) return [];
    // data
    Uint8List fileBytes = await file.readAsBytes();
    String base64Data = base64.encode(fileBytes);
    // bytesLength
    int bytesLength = base64Data.length;
    if (bytesLength < prePieceLength * minPiecesTotal) return [];
    // total (5~257)
    int total;
    if (bytesLength < prePieceLength * maxPiecesTotal) {
      total = bytesLength ~/ prePieceLength;
      if (bytesLength % prePieceLength > 0) {
        total += 1;
      }
    } else {
      total = maxPiecesTotal;
    }
    // parity(>=2)
    int parity = total ~/ piecesParity;
    if (parity <= minPiecesTotal ~/ piecesParity) {
      parity = minPiecesTotal ~/ piecesParity;
    }
    return [base64Data, bytesLength, total, parity];
  }
}
