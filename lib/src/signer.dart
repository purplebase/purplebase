part of purplebase;

mixin Signable<E extends Event<E>, P extends PartialEvent<P, E>> {
  Future<E> signWith(Signer signer) {
    return signer.sign<E, P>(this as P);
  }
}

// class PKSigner implements Signer {
//   @override
//   E sign<E extends Event<E>, P extends PartialEvent<P, E>>(P model) {
//     return Event.getConstructor<E>(model.kind)!.call(
//         {...model.toMap(), 'id': '1whatever', 'sig': 'lalala', 'pubkey': '1p'});
//   }
// }

abstract class Signer {
  Future<Signer> initialize();
  Future<String?> getPublicKey();
  Future<E> sign<E extends Event<E>, P extends PartialEvent<P, E>>(
      P partialEvent,
      {String? asUser});
}

class Bip340PrivateKeySigner extends Signer {
  final String privateKey;
  Bip340PrivateKeySigner(this.privateKey);

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
  Future<E> sign<E extends Event<E>, P extends PartialEvent<P, E>>(
      P partialEvent,
      {String? asUser}) async {
    final pubkey = BaseUtil.getPublicKey(privateKey);
    final id = partialEvent.getEventId(pubkey);
    // TODO: Should aux be random? random.nextInt(256)
    final aux = hex.encode(List<int>.generate(32, (i) => 1));
    final signature = bip340.sign(privateKey, id.toString(), aux);
    final map = _prepare(partialEvent.toMap(), id, pubkey, signature);
    return Event.getConstructor<E>(partialEvent.kind)!.call(map);
  }
}
