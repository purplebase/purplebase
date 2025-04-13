import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/request.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

/// Singleton
class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  static PurplebaseStorageNotifier? _instance;

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

  late final Database db;
  var _initialized = false;
  var applyLimit = true;

  Isolate? _isolate;
  SendPort? _sendPort;
  final _initCompleter = Completer<void>();
  StreamSubscription? sub;

  /// Initialize the storage with a configuration
  @override
  Future<void> initialize(StorageConfiguration config) async {
    await super.initialize(config);

    if (_initialized) return;

    // final dirPath = path.join(Directory.current.path, config.databasePath);
    // db = sqlite3.open(dirPath);

    // // Configure sqlite: 1 GB memory mapped
    // db.execute('''
    //   PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
    //   PRAGMA page_size = 4096;
    //   PRAGMA cache_size = -20000;
    //   ''');

    // Initialize isolate
    if (_isolate != null) return _initCompleter.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(isolateEntryPoint, [
      receivePort.sendPort,
      config,
    ]);

    sub = receivePort.listen((message) {
      if (_sendPort == null && message is SendPort) {
        _sendPort = message;
        _initCompleter.complete();
      } else {
        state = (message as (Set<String>, ResponseMetadata));
      }
    });

    await _initCompleter.future;
    _initialized = true;
  }

  /// Client-facing save method
  /// (framework calls _save internally in isolate)
  @override
  Future<void> save(
    Set<Event> events, {
    String? relayGroup,
    bool publish = true,
  }) async {
    if (events.isEmpty) return;

    final maps = events.map((e) => e.toMap()).toList();

    final response = await _sendMessage(
      SaveIsolateOperation(
        events: maps,
        relayGroup: relayGroup,
        publish: publish,
      ),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    // Empty response metadata as these events do not come from a relay
    final responseMetadata = ResponseMetadata(relayUrls: {});
    final record = response.result as Set<String>;
    state = (record, responseMetadata);
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    final response = await _sendMessage(ClearIsolateOperation());

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  // @override
  // List<Event> querySync(RequestFilter req, {bool applyLimit = true}) {
  //   Iterable<Map<String, dynamic>> events;
  //   // Note: applyLimit parameter is not used here as the limit comes from req.limit
  //   final relayUrls = config.getRelays(relayGroup: req.on, useDefault: false);
  //   final (sql, params) = req.toSQL(relayUrls: relayUrls);
  //   final statement = db.prepare(sql);
  //   try {
  //     final result = statement.selectWith(StatementParameters.named(params));

  //     events = result.decoded();
  //   } finally {
  //     statement.dispose();
  //   }

  //   return events
  //       .map((e) => Event.getConstructorForKind(e['kind'])!.call(e, ref))
  //       .toList()
  //       .cast();
  // }

  @override
  Future<List<Event>> query(RequestFilter req, {bool applyLimit = true}) async {
    final relayUrls = config.getRelays(relayGroup: req.on, useDefault: false);
    final (sql, params) = req.toSQL(relayUrls: relayUrls);

    final response = await _sendMessage(
      QueryIsolateOperation(sql: sql, params: params),
    );

    final events = (response.result as Iterable<Row>).decoded();

    return events
        .map((e) => Event.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<void> send(RequestFilter req) async {
    final response = await _sendMessage(SendEventIsolateOperation(req: req));

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  Future<void> cancel(RequestFilter req) async {
    // TODO: implement cancel
  }

  @override
  void dispose() {
    if (!_initialized || _isolate == null) return;

    sub?.cancel();

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _initialized = false;

    if (mounted) {
      super.dispose();
    }
  }

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    await _initCompleter.future;

    final receivePort = ReceivePort();
    _sendPort!.send((operation, receivePort.sendPort));

    return await receivePort.first as IsolateResponse;
  }
}

extension on Iterable<Row> {
  List<Map<String, dynamic>> decoded() {
    return map(
      (row) => {
        'id': row['id'],
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': row['content'],
        'sig': row['sig'],
        'tags': jsonDecode(row['tags']),
        'relays': row['relays'] != null ? jsonDecode(row['relays']) : null,
      },
    ).toList();
  }
}
