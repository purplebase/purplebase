part of purplebase;

abstract class Signer {
  Future<Signer> initialize();
  Future<String?> getPublicKey();
  Future<T> sign<T extends BaseEvent<T>>(T model, {String? asUser});
}

class PrivateKeySigner extends Signer {
  final String privateKey;
  PrivateKeySigner(this.privateKey);

  @override
  Future<Signer> initialize() async {
    return this;
  }

  @override
  Future<String?> getPublicKey() async {
    return BaseUtil.getPublicKey(privateKey);
  }

  Map<String, dynamic> _prepare(
      Map<String, dynamic> map, String id, String pubkey, String signature,
      {DateTime? createdAt}) {
    return map
      ..['id'] = id
      ..['pubkey'] = pubkey
      ..['sig'] = signature
      ..['created_at'] = createdAt ?? map['created_at'] ?? DateTime.now();
  }

  @override
  Future<T> sign<T extends BaseEvent<T>>(T model, {String? asUser}) async {
    final pubkey = BaseUtil.getPublicKey(privateKey);
    final id = model.getEventId(pubkey);
    // TODO: Should aux be random? random.nextInt(256)
    final aux = hex.encode(List<int>.generate(32, (i) => 1));
    final signature = bip340.sign(privateKey, id.toString(), aux);
    final map = _prepare(model.toMap(), id, pubkey, signature);
    return BaseEvent.constructorForKind<T>(model.kind)!.call(map);
  }
}
