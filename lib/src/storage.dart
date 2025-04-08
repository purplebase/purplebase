import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/request.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  static PurplebaseStorageNotifier? _instance; // singleton

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

  late final Database db;
  var _initialized = false;
  var applyLimit = true;

  Isolate? _isolate;
  SendPort? _sendPort;
  final Completer<void> _initCompleter = Completer<void>();

  /// Initialize the storage with a configuration
  @override
  Future<void> initialize(StorageConfiguration config) async {
    await super.initialize(config);

    if (_initialized) return;

    db = sqlite3.open(config.databasePath);

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

    receivePort.listen((message) {
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

  @override
  Future<void> save(Set<Event> events) async {
    final maps = events.map((e) => e.toMap()).toList();
    if (maps.isEmpty) return;

    // Check for existing IDs in database and remove
    // Reuse logic on RequestFilter#toSQL() for this
    // Exclude nulls, we have no idea what is coming in
    final requestedIds = maps.map((m) => m['id']?.toString()).nonNulls.toSet();
    final (idsSql, idsParams) = RequestFilter(
      ids: requestedIds,
    ).toSQL(returnIds: true);

    final response = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.query,
        sql: idsSql,
        parameters: [idsParams],
      ),
    );

    if (!response.success) {
      throw IsolateException(response.error ?? 'Unknown database error');
    }

    final savedIds = response.result as List<Map<String, dynamic>>;

    final idsToSave = requestedIds.difference(
      savedIds.map((e) => e['id']!).toSet(),
    );

    final mapsToSave = maps.where((m) => idsToSave.contains(m['id'])).toList();

    final response2 = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.save,
        parameters: mapsToSave,
        config: config,
      ),
    );

    if (!response2.success) {
      throw IsolateException(response.error ?? 'Unknown database error');
    }

    final record = response2.result as (Set<String>, ResponseMetadata);
    state = StorageSignal(record);
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    final response = await _sendMessage(
      IsolateMessage(type: IsolateOperationType.clear, parameters: []),
    );

    if (!response.success) {
      throw IsolateException(response.error ?? 'Unknown database error');
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
        'id': row['id'],
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
  Future<List<Event>> query(
    RequestFilter req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) async {
    final (sql, params) = req.toSQL(onIds: onIds);

    final response = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.query,
        sql: sql,
        parameters: [params],
      ),
    );

    final events = (response.result as List).map(
      (row) => {
        'id': row['id'],
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

  /// Close the isolate connection
  @override
  Future<void> close() async {
    if (!_initialized) return;
    await dispose();
    _initialized = false;
  }

  @override
  Future<void> send(RequestFilter req, {Set<String>? relayUrls}) async {
    final response = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.send,
        sendParameters: (req, relayUrls),
      ),
    );

    if (!response.success) {
      throw IsolateException(response.error ?? 'Unknown pool error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_isolate == null) return;

    await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.close,
        sql: '',
        replyPort: const DummySendPort(),
      ),
    );

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;

    if (mounted) {
      super.dispose();
    }
  }

  Future<IsolateResponse> _sendMessage(IsolateMessage message) async {
    await _initCompleter.future;

    final responsePort = ReceivePort();
    final msg = IsolateMessage(
      type: message.type,
      sql: message.sql,
      parameters: message.parameters,
      sendParameters: message.sendParameters,
      config: message.config,
      replyPort: responsePort.sendPort,
    );

    _sendPort!.send(msg);

    return await responsePort.first as IsolateResponse;
  }

  // Previous query methods

  // Future<List<Map<String, dynamic>>> queryRaw(RequestFilter req) async {
  //   final completer = Completer<List<Map<String, dynamic>>>();

  //   final relayUrls = pool!.relayUrls;
  //   final allEvents = <Map<String, dynamic>>[];
  //   final eoses = <String, bool>{for (final r in relayUrls) r: false};

  //   _closeFns[req.subscriptionId] = addListener((message) {
  //     if (message.subscriptionId != req.subscriptionId) return;
  //     switch (message) {
  //       case EoseWithEventsRelayMessage(:final events, :final relayUrl):
  //         eoses[relayUrl!] = true;
  //         for (final event in events) {
  //           if (!allEvents.any((e) => e['id'] == event['id'])) {
  //             allEvents.add(event);
  //           }
  //         }
  //         // If there are at least as much EOSEs as connected relays, we're good
  //         final enoughEoses = eoses.values.where((v) => v).length >=
  //             pool!.connectedRelayUrls.length;
  //         if (enoughEoses && !completer.isCompleted) {
  //           final allEventsSorted = allEvents.sortedByCompare(
  //               (m) => m['created_at'] as int, (a, b) => b.compareTo(a));
  //           completer.complete(allEventsSorted);
  //           scheduleMicrotask(() {
  //             _closeFns[req.subscriptionId]?.call();
  //           });
  //         }
  //         break;
  //       case ErrorRelayMessage(:final error):
  //         completer.completeError(Exception(error));
  //         break;
  //       default:
  //     }
  //   }, fireImmediately: false);

  //   send(req);
  //   for (final relayUrl in relayUrls) {
  //     _resultsOnEose[(relayUrl, req.subscriptionId)] = [];
  //   }

  //   return completer.future;
  // }

  // Future<List<E>> query<E extends Event<E>>(
  //     {Set<String>? ids,
  //     Set<String>? authors,
  //     Map<String, dynamic>? tags,
  //     String? search,
  //     DateTime? since,
  //     DateTime? until,
  //     int? limit,
  //     Iterable<String>? relayUrls}) async {
  //   final req = RequestFilter(
  //       kinds: {Event.types[E.toString()]!.kind},
  //       ids: ids ?? {},
  //       authors: authors ?? {},
  //       tags: tags,
  //       search: search,
  //       since: since,
  //       until: until,
  //       limit: limit);

  //   final result = await queryRaw(req);
  //   return result.map(Event.getConstructor<E>()!.call).toList();
  // }

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
