part of purplebase;

class BaseUser extends BaseEvent<BaseUser> {
  BaseUser({
    DateTime? createdAt,
    Set<String>? pubkeys,
    Set<String>? tags,
    String? name,
    String? avatarUrl,
    String? lud16,
  }) : super(
          createdAt: createdAt,
          pubkeys: pubkeys,
          tags: tags,
          content: jsonEncode(<String, dynamic>{
            'name': name,
            'picture': avatarUrl,
            'lud16': lud16
          }.nonNulls),
        );

  BaseUser.fromJson(Map<String, dynamic> map) : super.fromJson(map);

  BaseUser copyWith({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? tags,
    String? name,
  }) {
    return BaseUser(
      createdAt: createdAt ?? this.createdAt,
      pubkeys: pubkeys ?? this.pubkeys,
      tags: tags ?? this.tags,
      name: name ?? this.name,
    );
  }

  Map<String, dynamic> get _content =>
      content.isNotEmpty ? jsonDecode(content) : {};

  @override
  int get kind => _kindFor<BaseUser>();

  String? get name {
    var name = _content['name'] as String?;
    if (name == null || name.isEmpty) {
      name = _content['display_name'] as String?;
    }
    if (name == null || name.isEmpty) {
      name = _content['displayName'] as String?;
    }
    return name;
  }

  String? get nip05 => _content['nip05'];

  String get npub => bech32Encode('npub', pubkey);
  String? get avatarUrl => _content['picture'];
}

extension Bech32StringX on String {
  String get npub => bech32Encode('npub', this);
  String get hexKey => bech32Decode(this);
}

String bech32Encode(String prefix, String hexData) {
  final data = hex.decode(hexData);
  final convertedData = convertBits(data, 8, 5, true);
  final bech32Data = Bech32(prefix, convertedData);
  return bech32.encode(bech32Data);
}

String bech32Decode(String bech32Data) {
  final decodedData = bech32.decode(bech32Data);
  final convertedData = convertBits(decodedData.data, 5, 8, false);
  return hex.encode(convertedData);
}

List<int> convertBits(List<int> data, int fromBits, int toBits, bool pad) {
  var acc = 0;
  var bits = 0;
  final maxv = (1 << toBits) - 1;
  final result = <int>[];

  for (final value in data) {
    if (value < 0 || value >> fromBits != 0) {
      throw Exception('Invalid value: $value');
    }
    acc = (acc << fromBits) | value;
    bits += fromBits;

    while (bits >= toBits) {
      bits -= toBits;
      result.add((acc >> bits) & maxv);
    }
  }

  if (pad) {
    if (bits > 0) {
      result.add((acc << (toBits - bits)) & maxv);
    }
  } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
    throw Exception('Invalid data');
  }

  return result;
}

extension on Map<String, dynamic> {
  Map<String, dynamic> get nonNulls {
    return {
      for (final e in entries)
        if (e.value != null) e.key: e.value,
    };
  }
}
