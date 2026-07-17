import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

final _zlib = ZLibCodec(
  level: ZLibOption.minMemLevel,
  strategy: ZLibOption.strategyRle,
);

/// Zlib compression/decompression and storage ID generation for events.
class EventCodec {
  /// Encode events for database storage.
  ///
  /// Returns the compressed events (with `:` prefixed param keys) and
  /// a map of storage-ID → tags for tag insertion.
  static (Set<Map<String, dynamic>> events, Map<String, List> tagsForId)
      encode(
    Iterable<Map<String, dynamic>> events, {
    bool keepSignatures = true,
  }) {
    final tagsForId = <String, List>{};

    final encoded = events.map((e) {
      const expectedFields = {
        'id', 'pubkey', 'kind', 'created_at', 'content', 'tags', 'sig',
      };
      final sanitized = <String, dynamic>{};
      for (final entry in e.entries) {
        if (expectedFields.contains(entry.key)) {
          sanitized[entry.key] = entry.value;
        }
      }
      e = sanitized;

      final eventId = e['id'] as String;
      e['id'] = storageId(e);

      final tags = tagsForId[e['id']] = e.remove('tags');

      final sig = e.remove('sig');
      final blobMap = {
        'content': e.remove('content'),
        'id': eventId,
        'tags': tags,
        if (keepSignatures) 'sig': sig,
      };
      e['blob'] = _zlib.encode(utf8.encode(jsonEncode(blobMap)));

      return {for (final entry in e.entries) ':${entry.key}': entry.value};
    }).toSet();

    return (encoded, tagsForId);
  }

  /// Decode rows from the database back into event maps.
  static List<Map<String, dynamic>> decode(
      Iterable<Map<String, dynamic>> rows) {
    return rows.map((row) {
      if (!row.containsKey('blob')) return row;

      final decodedBlob = _zlib.decode(row['blob']);
      final blob = jsonDecode(utf8.decode(decodedBlob));
      final (content, tags, eventId, sig) = switch (blob) {
        {
          'content': final content,
          'tags': final tags,
          'id': final String eventId,
          'sig': final sig,
        } =>
          (content, tags, eventId, sig?.toString()),
        {
          'content': final content,
          'tags': final tags,
          'id': final String eventId,
        } =>
          (content, tags, eventId, null),
        [final content, final tags, ...final rest] => (
          content,
          tags,
          _legacyEventId(row, content: content, tags: tags),
          rest.firstOrNull?.toString(),
        ),
        _ => throw const FormatException('Invalid event storage blob.'),
      };

      return {
        'id': eventId,
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': content,
        if (sig != null) 'sig': sig,
        'tags': tags,
      };
    }).toList();
  }

  /// Compute the storage ID for an event.
  ///
  /// Replaceable events use `kind:pubkey:d_tag` as their ID.
  /// Regular events use the event's `id` field.
  static String storageId(Map<String, dynamic> event) {
    final tags = event['tags'] as Iterable;
    final dTag =
        (tags.firstWhereOrNull((e) => e[0] == 'd') as Iterable?)?.toList();
    return switch (event['kind']) {
      0 || 3 || >= 10000 && < 20000 || >= 30000 && < 40000 =>
        '${event['kind']}:${event['pubkey']}:${dTag != null ? dTag[1] : ''}',
      _ => event['id'],
    };
  }

  /// Reconstruct the canonical ID from legacy blobs that only retained the
  /// replaceable-event coordinate as their SQLite row ID.
  static String _legacyEventId(
    Map<String, dynamic> row, {
    required Object? content,
    required Object? tags,
  }) {
    final serializable = [
      0,
      row['pubkey'].toString().toLowerCase(),
      row['created_at'],
      row['kind'],
      tags,
      content,
    ];
    return sha256.convert(utf8.encode(jsonEncode(serializable))).toString();
  }
}
