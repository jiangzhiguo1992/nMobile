import 'package:sqflite_sqlcipher/sqflite.dart';

import '../common/locator.dart';
import '../helpers/error.dart';
import '../schema/private_group_item.dart';
import '../utils/logger.dart';

class PrivateGroupItemStorage with Tag {
  static String get tableName => 'PrivateGroupList';

  Database? get db => dbCommon.database;

  static String createSQL = '''
      CREATE TABLE `$tableName` (
        `id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        `group_id` VARCHAR(100),
        `invitee` VARCHAR(100),
        `inviter` VARCHAR(100),
        `invitee_signature` VARCHAR(200),
        `inviter_signature` VARCHAR(200),
        `invitee_raw_data` TEXT,
        `inviter_raw_data` TEXT,
        `invite_time` BIGINT,
        `invited_time` BIGINT,
        `expires_at` BIGINT,
        `create_at` BIGINT,
        `update_at` BIGINT
      )''';

  static create(Database db) async {
    // create table
    await db.execute(createSQL);

    // index
    await db.execute('CREATE UNIQUE INDEX `index_unique_private_group_list_group_id` ON `$tableName` (`group_id`)');
    await db.execute('CREATE INDEX `index_private_group_list_invitee` ON `$tableName` (`invitee`)');
    await db.execute('CREATE INDEX `index_private_group_list_inviter` ON `$tableName` (`inviter`)');
    await db.execute('CREATE INDEX `index_private_group_list_invitee_signature` ON `$tableName` (`invitee_signature`)');
    await db.execute('CREATE INDEX `index_private_group_list_inviter_signature` ON `$tableName` (`inviter_signature`)');
    await db.execute('CREATE INDEX `index_private_group_list_invite_time` ON `$tableName` (`invite_time`)');
    await db.execute('CREATE INDEX `index_private_group_list_invited_time` ON `$tableName` (`invited_time`)');
    await db.execute('CREATE INDEX `index_private_group_list_expires_at` ON `$tableName` (`expires_at`)');
    await db.execute('CREATE INDEX `index_private_group_list_create_at` ON `$tableName` (`create_at`)');
    await db.execute('CREATE INDEX `index_private_group_list_update_at` ON `$tableName` (`update_at`)');
  }

  Future<PrivateGroupItemSchema?> insert(PrivateGroupItemSchema schema) async {
    Map<String, dynamic> entity = schema.toMap();

    try {
      int? id = await db?.insert(tableName, entity);

      if (id != null && id > 0) {
        schema.id = id;
        logger.v("$TAG - insert - success - schema:$schema");
        return schema;
      }
      logger.w("$TAG - insert - empty - schema:$schema");
    } catch (e) {
      handleError(e);
    }
    return null;
  }

  Future<List<PrivateGroupItemSchema>?> query(String groupId) async {
    try {
      List<Map<String, dynamic>>? res = await db?.transaction((txn) {
        return txn.query(
          tableName,
          columns: ['*'],
          where: 'group_id = ?',
          whereArgs: [groupId],
        );
      });
      if (res != null && res.length > 0) {
        List<PrivateGroupItemSchema> list = [];
        for (var i = 0; i < res.length; i++) {
          if (res[i].isEmpty || res[i].isEmpty) continue;
          Map<String, dynamic> map = res[i];
          PrivateGroupItemSchema schema = PrivateGroupItemSchema.fromMap(map);
          list.add(schema);
        }
        logger.v("$TAG - query - success");
        return list;
      }
      logger.v("$TAG - query - empty - groupId:$groupId");
    } catch (e) {
      handleError(e);
    }
    return null;
  }

  Future<int?> delete() async {
    try {
      int? res = await db?.transaction((txn) {
        return txn.delete(tableName);
      });
      return res;
    } catch (e) {
      handleError(e);
    }
    return null;
  }

  Future<void> dropTable() async {
    try {
      await db?.execute('DROP TABLE $tableName');
    } catch (e) {
      handleError(e);
    }
  }
}