// Room events, Client-Server API v1.19 "Events" and "Room Events".
//
// An `Event` keeps the JSON it was decoded from in `raw`, so nothing the
// server sent is lost; typed views of the content are decoded on demand by
// `Event::kind` and the per-type parsers.

///|
/// Server-added data that is not covered by the event signature.
pub struct Unsigned {
  /// Milliseconds since the event was sent, as of when it was delivered.
  age : Int64?
  /// Present on events sent by this device, echoing the transaction ID.
  transaction_id : String?
  /// The previous content of a state event, if any.
  prev_content : Map[String, Json]?
  /// The redaction event, if this event has been redacted.
  redacted_because : Json?
  raw : Map[String, Json]
} derive(Eq, Debug)

///|
fn decode_unsigned(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> Unsigned raise @json.JsonDecodeError {
  {
    age: @jsonx.opt_int(m, "age", path),
    transaction_id: @jsonx.opt_string(m, "transaction_id", path),
    prev_content: @jsonx.opt_object(m, "prev_content", path),
    redacted_because: match m.get("redacted_because") {
      None | Some(Null) => None
      v => v
    },
    raw: m,
  }
}

///|
/// A room event as delivered by `/sync`, `/messages` or `/event`.
pub struct Event {
  kind_str : String
  event_id : @ids.EventId
  /// The sender as sent by the server. Kept as a string: historical user IDs
  /// may not parse as current `UserId`s; use `Event::sender_id` to parse.
  sender : String
  origin_server_ts : Int64
  /// Omitted inside `/sync` room sections, where the room is implied.
  room_id : @ids.RoomId?
  /// Present exactly when this is a state event.
  state_key : String?
  content : Map[String, Json]
  unsigned : Unsigned?
  raw : Map[String, Json]
} derive(Eq, Debug)

///|
pub fn Event::decode(
  json : Json,
  path : @json.JsonPath,
) -> Event raise @json.JsonDecodeError {
  let m = @jsonx.object(json, path)
  let content = @jsonx.opt_object(m, "content", path).unwrap_or(Map([]))
  let unsigned = match @jsonx.opt_object(m, "unsigned", path) {
    Some(u) => Some(decode_unsigned(u, path.add_key("unsigned")))
    None => None
  }
  {
    kind_str: @jsonx.string(m, "type", path),
    event_id: @jsonx.decode(m, "event_id", path),
    sender: @jsonx.string(m, "sender", path),
    origin_server_ts: @jsonx.int(m, "origin_server_ts", path),
    room_id: @jsonx.opt_decode(m, "room_id", path),
    state_key: @jsonx.opt_string(m, "state_key", path),
    content,
    unsigned,
    raw: m,
  }
}

///|
pub impl @json.FromJson for Event with fn from_json(json, path) {
  Event::decode(json, path)
}

///|
/// The original JSON object.
pub impl ToJson for Event with fn to_json(self) {
  Json::object(self.raw)
}

///|
/// Parses an event from JSON text.
pub fn Event::parse(text : String) -> Event raise @json.JsonDecodeError {
  let json = @json.parse(text) catch {
    e => @jsonx.fail(@jsonx.root(), e.to_string())
  }
  Event::decode(json, @jsonx.root())
}

///|
/// The event type, e.g. `m.room.message`.
pub fn Event::event_type(self : Event) -> String {
  self.kind_str
}

///|
pub fn Event::is_state(self : Event) -> Bool {
  self.state_key is Some(_)
}

///|
pub fn Event::sender_id(self : Event) -> @ids.UserId? {
  try @ids.UserId::parse(self.sender) catch {
    _ => None
  } noraise {
    u => Some(u)
  }
}

///|
/// The transaction ID echoed back on events this device sent.
pub fn Event::transaction_id(self : Event) -> String? {
  self.unsigned.bind(u => u.transaction_id)
}

///|
pub fn Event::is_redacted(self : Event) -> Bool {
  self.unsigned is Some({ redacted_because: Some(_), .. })
}

///|
/// For `m.room.redaction` events, the redacted event. Room version 11 moved
/// `redacts` into `content`; older versions have it at the top level.
pub fn Event::redacts(self : Event) -> @ids.EventId? {
  guard self.kind_str == "m.room.redaction" else { return None }
  let v = match self.content.get("redacts") {
    Some(String(s)) => s
    _ =>
      match self.raw.get("redacts") {
        Some(String(s)) => s
        _ => return None
      }
  }
  try @ids.EventId::parse(v) catch {
    _ => None
  } noraise {
    e => Some(e)
  }
}

///|
/// Returns a copy with `room_id` filled in, for events from `/sync` room
/// sections that omit it.
pub fn Event::in_room(self : Event, room_id : @ids.RoomId) -> Event {
  if self.room_id is Some(_) {
    return self
  }
  { ..self, room_id: Some(room_id), }
}

///|
/// A stripped state event, as found in invite and knock state. It has no
/// event ID or timestamp.
pub struct StrippedState {
  kind_str : String
  state_key : String
  sender : String
  content : Map[String, Json]
} derive(Eq, Debug)

///|
pub impl @json.FromJson for StrippedState with fn from_json(json, path) {
  let m = @jsonx.object(json, path)
  {
    kind_str: @jsonx.string(m, "type", path),
    state_key: @jsonx.string(m, "state_key", path),
    sender: @jsonx.string(m, "sender", path),
    content: @jsonx.opt_object(m, "content", path).unwrap_or(Map([])),
  }
}

///|
pub extend Event with ToJson::{to_json}
