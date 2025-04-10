import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:path/path.dart' as path;
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

    final dirPath = path.join(Directory.current.path, config.databasePath);
    print('Opening database at $dirPath [main isolate]');
    db = sqlite3.open(dirPath);

    // Configure sqlite: 1 GB memory mapped
    db.execute('''
      PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -20000;
      ''');

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
        state = StorageSignal(message as (Set<String>, ResponseMetadata));
      }
    });

    await _initCompleter.future;
    _initialized = true;
  }

  /// Client-facing save method
  /// (framework calls _save internally in isolate)
  @override
  Future<void> save(Set<Event> events, {String? relayGroup}) async {
    if (events.isEmpty) return;

    final maps = events.map((e) => e.toMap()).toList();

    final response = await _sendMessage(SaveIsolateOperation(events: maps));

    if (!response.success) {
      throw IsolateException(response.error ?? 'Unknown database error');
    }

    // Since these events have been created locally and
    // do not come from a relay, their metadata is empty
    // TODO: ^
    final r = ResponseMetadata(relayUrls: {});
    final record = response.result as Set<String>;
    state = StorageSignal((record, r));
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    final response = await _sendMessage(ClearIsolateOperation());

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  List<Event> querySync(
    RequestFilter req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) {
    // Note: applyLimit parameter is not used here as the limit comes from req.limit
    final (sql, params) = req.toSQL(onIds: onIds);
    final statement = db.prepare(sql);
    final result = statement.selectWith(
      StatementParameters.named(params),
    ); // params
    statement.dispose();
    final events = result.map(
      (row) => {
        // Apply lid (latest ID) of a replaceable, otherwise regular ID
        'id': row['lid'] ?? row['id'],
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': row['content'],
        'sig': row['sig'],
        'tags': jsonDecode(row['tags']),
        'relays': row['relays'] != null ? jsonDecode(row['relays']) : null,
      },
    );

    return events
        .map((e) => Event.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<List<Event>> query(
    RequestFilter req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) async {
    final (sql, params) = req.toSQL(onIds: onIds);

    final response = await _sendMessage(
      QueryIsolateOperation(sql: sql, params: params),
    );

    // TODO: Repeated code
    final events = (response.result as List).map(
      (row) => {
        'id': row['lid'] ?? row['id'],
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': row['content'],
        'sig': row['sig'],
        'tags': jsonDecode(row['tags']),
      },
    );

    return events
        .map((e) => Event.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<void> send(RequestFilter req, {String? relayGroup}) async {
    final response = await _sendMessage(
      SendEventIsolateOperation(req: req, relayGroup: relayGroup),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  Future<void> dispose() async {
    if (!_initialized || _isolate == null) return;

    sub?.cancel();

    await _sendMessage(CloseIsolateOperation());

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

  // Future<void> publish(Event event) async {
  //   final completer = Completer<void>();

  //   pool!.send(jsonEncode(["EVENT", event.toMap()]));

  //   _closeFns[event.event.id.toString()] = addListener((message) {
  //     if (message.subscriptionId != null &&
  //         event.event.id.toString() != message.subscriptionId) {
  //       return;
  //     }

  //     if (message is PublishedEventRelayMessage) {
  //       if (message.accepted) {
  //         if (!completer.isCompleted) {
  //           completer.complete();
  //         }
  //       } else {
  //         if (!completer.isCompleted) {
  //           final error = message.message ?? 'Not accepted';
  //           completer.completeError(Exception(error));
  //         }
  //       }
  //     }
  //   });
  //   return completer.future;
  // }
}

// TODO: Should extend StorageConfiguration
class PurplebaseConfiguration {
  final Duration idleTimeout;
  final Duration streamingBufferWindow;
  PurplebaseConfiguration({
    this.idleTimeout = const Duration(minutes: 5),
    this.streamingBufferWindow = const Duration(seconds: 2),
  });
}

final purplebaseConfigurationProvider = Provider(
  (_) => PurplebaseConfiguration(),
);
