import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_image/firebase_image.dart';
import 'package:firebase_image/src/cache_manager/abstract.dart';
import 'package:firebase_image/src/image_object.dart';
import 'package:firebase_image/src/utils/map_utils.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:idb_sqflite/idb_sqflite.dart';

class FirebaseImageCacheManager extends AbstractFirebaseImageCacheManager {
  static const String key = 'firebase_image';

  late Database db;
  static const String dbName = '$key.db';
  static const String table = 'images';

  FirebaseImageCacheManager(cacheRefreshStrategy) : super(cacheRefreshStrategy);

  // Interface methods

  Future<void> open() async {
    db = await idbFactoryNative.open(dbName, version: 1, onUpgradeNeeded: (e) {
      var db = e.database;
      db.createObjectStore(table);
    });
  }

  Future<FirebaseImageObject?> getObject(
      String uri, FirebaseImage image) async {
    var store = _dbReadableTxn;
    var map = asMap<String, Object?>(await store.getObject(uri));
    try {
      FirebaseImageObject? returnObject = FirebaseImageObject.fromMap(map);
      returnObject.reference = _getImageRef(returnObject, image.firebaseApp);
      if (CacheRefreshStrategy.BY_METADATA_DATE == this.cacheRefreshStrategy) {
        checkForUpdate(returnObject, image); // Check for update in background
      }
      return returnObject;
    } catch (e) {
    }
    return null;
  }

  Future<List<FirebaseImageObject>> getAllObjects() async {
    List<FirebaseImageObject?> list = <FirebaseImageObject>[];
    var store = _dbReadableTxn;
    // ignore: cancel_subscriptions
    StreamSubscription subscription = store
        .openCursor(direction: idbDirectionPrev, autoAdvance: true)
        .listen((cursor) {
      try {
        var map = asMap<String, Object?>(cursor.value);

        if (map != null) {
          list.add(FirebaseImageObject.fromMap(map));
        }
      } catch (e) {
        print("error $e");
      }
    });
    await subscription.asFuture();

    return list as FutureOr<List<FirebaseImageObject>>;
  }

  Future<Uint8List?> getLocalFileBytes(FirebaseImageObject? object) async {
    try {
      if (object!.localPath != null) {
        Uint8List bytes = base64Decode(object.localPath!);
        return bytes;
      }
    } catch (e) {
      print("error $e");
    }
    return null;
  }

  Future<Uint8List?> upsertRemoteFileToCache(
      FirebaseImageObject object, int maxSizeBytes) async {
    if (CacheRefreshStrategy.BY_METADATA_DATE == this.cacheRefreshStrategy) {
      object.version = (await object.reference.getMetadata())
              .updated
              ?.millisecondsSinceEpoch ??
          0;
    }
    Uint8List? bytes = await getRemoteFileBytes(object, maxSizeBytes);
    await _filePut(object, bytes);
    return bytes;
  }

  // Firestore&-related methods

  Reference _getImageRef(FirebaseImageObject object, FirebaseApp? firebaseApp) {
    FirebaseStorage storage =
        FirebaseStorage.instanceFor(app: firebaseApp, bucket: object.bucket);
    return storage.ref().child(object.remotePath);
  }

  // Filesystem-related methods

  Future<FirebaseImageObject> _filePut(
      FirebaseImageObject object, final bytes) async {
    object.localPath = base64Encode(bytes);
    return await _dbUpsert(object);
  }

  // DB-related methods

  ObjectStore get _dbWritableTxn {
    var txn = db.transaction(table, idbModeReadWrite);
    var store = txn.objectStore(table);
    return store;
  }

  ObjectStore get _dbReadableTxn {
    var txn = db.transaction(table, idbModeReadOnly);
    var store = txn.objectStore(table);
    return store;
  }

  Future<bool> _dbCheckForEntry(FirebaseImageObject object) async {
    var store = _dbReadableTxn;
    var map = asMap<String, Object?>(await store.getObject(object.uri));
    return map != null && map.length > 0;
  }

  Future<FirebaseImageObject> _dbInsert(FirebaseImageObject model) async {
    var store = _dbWritableTxn;
    await store.add(model.toMap(), model.uri);
    return model;
  }

  Future<FirebaseImageObject> _dbUpdate(FirebaseImageObject model) async {
    var store = _dbWritableTxn;
    store.put(model.toMap(), model.uri);
    return model;
  }

  Future<FirebaseImageObject> _dbUpsert(FirebaseImageObject object) async {
    if (await _dbCheckForEntry(object)) {
      return await _dbUpdate(object);
    } else {
      return await _dbInsert(object);
    }
  }
}
