part of purplebase;

class ZapReceipt = RegularEvent<ZapReceipt> with ZapReceiptMixin;

mixin ZapReceiptMixin on EventBase<ZapReceipt> {
  String get eventId => event.getTag('e')!;
  String get receiverPubkey => event.getTag('p')!;
  Map<String, dynamic> get description => event.getTag('description') != null
      ? Map<String, dynamic>.from(jsonDecode(event.getTag('description')!))
      : {};
  String get senderPubkey => event.getTag('P') ?? description['pubkey'];

  /// Amount in sats
  int get amount {
    return getSatsFromBolt11(event.getTag('bolt11')!);
  }
}
