// Outbox persistence. Messages in flight when the snapshot was taken are
// restored as queued: the server may or may not have them, and resending
// with the same transaction ID is safe.

///|
fn SendState::to_json(self : SendState) -> Json {
  match self {
    Queued | InFlight => { "state": "queued" }
    Retrying(at_ms~) =>
      { "state": "retrying", "at_ms": Json::number(at_ms.to_double()) }
    Sent(e) => { "state": "sent", "event_id": e.to_json() }
    Failed(r) => { "state": "failed", "reason": r }
  }
}

///|
pub impl ToJson for Outbox with fn to_json(self) {
  let items = self.items.map(p => {
    let m : Map[String, Json] = {
      "txn_id": Json::string(p.txn_id),
      "room_id": p.room_id.to_json(),
      "event_type": Json::string(p.event_type),
      "content": p.content,
      "attempts": Json::number(p.attempts.to_double()),
      "state": p.state.to_json(),
    }
    Json::object(m)
  })
  {
    "prefix": self.prefix,
    "counter": Json::number(self.counter.to_double()),
    "items": Json::array(items),
  }
}

///|
pub extend Outbox with ToJson::{to_json}

///|
fn decode_state(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> SendState raise @json.JsonDecodeError {
  match @jsonx.string(m, "state", path) {
    "queued" => Queued
    "retrying" => Retrying(at_ms=@jsonx.int(m, "at_ms", path))
    "sent" => Sent(@jsonx.decode(m, "event_id", path))
    "failed" => Failed(@jsonx.opt_string(m, "reason", path).unwrap_or(""))
    other => @jsonx.fail(path.add_key("state"), "unknown state \{other}")
  }
}

///|
/// Restores an outbox from `Outbox::to_json`, with the given retry settings.
pub fn Outbox::from_json(
  json : Json,
  max_attempts~ : Int32 = 5,
  base_delay_ms~ : Int64 = 1000,
  max_delay_ms~ : Int64 = 60000,
) -> Outbox raise @json.JsonDecodeError {
  let root = @jsonx.root()
  let m = @jsonx.object(json, root)
  let out = Outbox::new(
    @jsonx.string(m, "prefix", root),
    max_attempts~,
    base_delay_ms~,
    max_delay_ms~,
  )
  out.counter = @jsonx.int(m, "counter", root)
  let ip = root.add_key("items")
  for i, item in @jsonx.array(m, "items", root) {
    let p = ip.add_index(i)
    let o = @jsonx.object(item, p)
    guard o.get("content") is Some(content) else {
      @jsonx.fail(p.add_key("content"), "missing content")
    }
    guard @jsonx.opt_object(o, "state", p) is Some(state) else {
      @jsonx.fail(p.add_key("state"), "missing state")
    }
    out.items.push({
      txn_id: @jsonx.string(o, "txn_id", p),
      room_id: @jsonx.decode(o, "room_id", p),
      event_type: @jsonx.string(o, "event_type", p),
      content,
      state: decode_state(state, p.add_key("state")),
      attempts: @jsonx.opt_int(o, "attempts", p).unwrap_or(0).to_int(),
    })
  }
  out
}
