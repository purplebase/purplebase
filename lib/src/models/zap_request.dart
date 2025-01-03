part of purplebase;

class ZapRequest = RegularEvent<ZapRequest> with ZapRequestMixin;
class PartialZapRequest = RegularPartialEvent<ZapRequest>
    with ZapRequestMixin, PartialZapRequestMixin;

mixin ZapRequestMixin on EventBase<ZapRequest> {}

mixin PartialZapRequestMixin on PartialEventBase<ZapRequest> {
  set comment(String? value) => value != null ? event.content = value : null;
  set amount(int value) => event.setTag('amount', value.toString());
  set relays(Iterable<String> value) => event.setTag('relays', value);
  set lnurl(String value) => event.setTag('lnurl', value);
}
