import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
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
        state = message as Set<String>;
      }
    });

    await _initCompleter.future;
    _initialized = true;
  }

  /// Client-facing save method
  /// (framework calls _save internally in isolate)
  @override
  Future<void> save(Set<Model<dynamic>> events) async {
    if (events.isEmpty) return;

    final maps = events.map((e) => e.toMap()).toList();

    final response = await _sendMessage(SaveIsolateOperation(events: maps));

    if (!response.success) {
      throw IsolateException(response.error);
    }

    state = response.result as Set<String>;
  }

  /// Publish to [relayGroup]
  @override
  Future<Set<PublishedStatus>> publish(
    Set<Model<dynamic>> events, {
    String? relayGroup,
  }) async {
    if (events.isEmpty) return {};

    final maps = events.map((e) => e.toMap()).toList();

    final response = await _sendMessage(
      PublishIsolateOperation(events: maps, relayGroup: relayGroup),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    return (response.result as List<Map<String, dynamic>>).map((r) {
      return PublishedStatus(
        eventId: r['id'],
        accepted: r['accepted'],
        message: r['message'],
      );
    }).toSet();
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    final response = await _sendMessage(ClearIsolateOperation());

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  List<E> querySync<E extends Model<dynamic>>(
    RequestFilter<E> req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) {
    Iterable<Map<String, dynamic>> events;
    // Note: applyLimit parameter is not used here as the limit comes from req.limit
    final relayUrls = config.getRelays(
      relayGroup: req.relayGroup,
      useDefault: false,
    );
    final (sql, params) = req.toSQL(relayUrls: relayUrls, onIds: onIds);
    final statement = db.prepare(sql);
    try {
      final result = statement.selectWith(StatementParameters.named(params));

      events = result.decoded();
    } finally {
      statement.dispose();
    }

    return events
        .map((e) => Model.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<List<E>> query<E extends Model<dynamic>>(
    RequestFilter<E> req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) async {
    // TODO: if req.storageOnly = false then must query relays and wait for response

    // If by any chance req is in cache, return that
    final cachedEvents =
        requestCache.values.firstWhereOrNull((m) => m.containsKey(req))?[req];
    if (cachedEvents != null) {
      return cachedEvents.cast();
    }

    // TODO: Should query for replaceable too
    // final replaceableIds = req.ids.where(kReplaceableRegexp.hasMatch);
    // final regularIds = {...req.ids}..removeAll(replaceableIds);

    // TODO: Test this relay requesting logic
    final relayUrls = config.getRelays(
      relayGroup: req.relayGroup,
      useDefault: false,
    );
    final (sql, params) = req.toSQL(relayUrls: relayUrls, onIds: onIds);

    final savedEvents = await _sendMessage(
      QueryIsolateOperation(sql: sql, params: params),
    ).then((r) {
      return (r.result as Iterable<Row>).decoded().map((e) {
        return Model.getConstructorForKind(e['kind']!)!.call(e, ref);
      });
    });
    // TODO: Explain why queryLimit=null
    final fetchedEvents = await fetch<E>(req.copyWith(queryLimit: null));

    return [...savedEvents, ...fetchedEvents].cast();
  }

  @override
  Future<List<E>> fetch<E extends Model<dynamic>>(RequestFilter<E> req) async {
    print('hitting fetch $req');
    if (req.remote == false) {
      return [];
    }

    final response = await _sendMessage(
      SendRequestIsolateOperation(req: req, waitForResult: true),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    final events = response.result as List<Map<String, dynamic>>;
    print('returning ${events.length} from fetch');
    return events
        .map((e) => Model.getConstructorForKind(e['kind'])!.call(e, ref))
        .cast<E>()
        .toList();
  }

  @override
  Future<void> cancel(RequestFilter req) async {
    if (!req.remote) return;

    final response = await _sendMessage(CancelIsolateOperation(req: req));

    if (!response.success) {
      throw IsolateException(response.error);
    }
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
