part of purplebase;

class ZapReceipt = RegularEvent<ZapReceipt> with ZapReceiptMixin;

mixin ZapReceiptMixin on EventBase<ZapReceipt> {
  String get eventId => event.getTag('e')!;
  String get receiverPubkey => event.getTag('p')!;
  String get senderPubkey => event.getTag('P')!;

  /// Amount in sats
  int get amount {
    return getSatsFromBolt11(event.getTag('bolt11')!);
  }
}
