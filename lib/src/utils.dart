import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';

final fastZlib = ZLibCodec(
  level: ZLibOption.minMemLevel,
  strategy: ZLibOption.strategyRle, // often yields a few more %
);

extension JSONIterableExt on Iterable<Map<String, dynamic>> {
  (Set<Map<String, dynamic>> events, Map<String, List> tagsForId) encoded({
    bool keepSignatures = true,
  }) {
    final tagsForId = <String, List>{};

    return (
      map((e) {
        // Get actual ID including replaceable
        e['id'] = _getIdForDatabase(e);

        // Save tags in a temporary map
        final tags = tagsForId[e['id']] = e.remove('tags');

        // Compress fields
        final sig = e.remove('sig');
        final blobMap = [e.remove('content'), tags, if (keepSignatures) sig];
        e['blob'] = fastZlib.encode(utf8.encode(jsonEncode(blobMap)));

        // Rename to prepend `:` for prepared statement
        return {for (final entry in e.entries) ':${entry.key}': entry.value};
      }).toSet(),
      tagsForId,
    );
  }

  List<Map<String, dynamic>> decoded() {
    return map((row) {
      // Return it if no need to decode
      if (!row.containsKey('blob')) return row;

      final decodedBlob = fastZlib.decode(row['blob']);
      final [content, tags, ...other] = jsonDecode(utf8.decode(decodedBlob));

      return {
        'id': row['id'],
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': content,
        if (other.isNotEmpty) 'sig': other.first.toString(),
        'tags': tags,
      };
    }).toList();
  }

  String _getIdForDatabase(Map<String, dynamic> event) {
    final tags = event['tags'] as Iterable;
    final dTag = (tags.firstWhereOrNull((e) => e[0] == 'd') as Iterable?)
        ?.toList();
    return switch (event['kind']) {
      0 || 3 || >= 10000 && < 20000 || >= 30000 && < 40000 =>
        '${event['kind']}:${event['pubkey']}:${dTag != null ? dTag[1] : ''}',
      _ => event['id'],
    };
  }
}
