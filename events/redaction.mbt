// Client-side redaction, following the algorithm of room version 11
// ("Redactions" in the room versions specification).
//
// Servers send already-redacted events after a redaction is processed; the
// client applies the same algorithm to the copies it stored before.

///|
let kept_top_level : Array[String] = [
  "event_id", "type", "room_id", "sender", "state_key", "content", "hashes", "signatures",
  "depth", "prev_events", "auth_events", "origin_server_ts",
]

///|
fn kept_content(event_type : String) -> Array[String]? {
  match event_type {
    "m.room.member" => Some(["membership", "join_authorised_via_users_server"])
    "m.room.create" => None
    "m.room.join_rules" => Some(["join_rule", "allow"])
    "m.room.power_levels" =>
      Some([
        "ban", "events", "events_default", "invite", "kick", "redact", "state_default",
        "users", "users_default",
      ])
    "m.room.history_visibility" => Some(["history_visibility"])
    "m.room.redaction" => Some(["redacts"])
    _ => Some([])
  }
}

///|
fn redact_content(
  event_type : String,
  content : Map[String, Json],
) -> Map[String, Json] {
  guard kept_content(event_type) is Some(keys) else { return content.copy() }
  let out : Map[String, Json] = Map([])
  for k in keys {
    if content.get(k) is Some(v) {
      out[k] = v
    }
  }
  // Member events keep only the `signed` part of a third-party invite.
  if event_type == "m.room.member" &&
    content.get("third_party_invite") is Some(Object(tpi)) &&
    tpi.get("signed") is Some(signed) {
    out["third_party_invite"] = { "signed": signed }
  }
  out
}

///|
/// Returns the redacted form of this event, with `unsigned.redacted_because`
/// set to `redaction`.
pub fn Event::redact(self : Event, redaction : Event) -> Event {
  let content = redact_content(self.kind_str, self.content)
  let raw : Map[String, Json] = Map([])
  for k in kept_top_level {
    if self.raw.get(k) is Some(v) {
      raw[k] = v
    }
  }
  raw["content"] = Json::object(content)
  let because = redaction.to_json()
  let unsigned_raw : Map[String, Json] = { "redacted_because": because }
  raw["unsigned"] = Json::object(unsigned_raw)
  {
    ..self,
    content,
    unsigned: Some({
      age: None,
      transaction_id: None,
      prev_content: None,
      redacted_because: Some(because),
      raw: unsigned_raw,
    }),
    raw,
  }
}

///|
pub impl ToJson for StrippedState with fn to_json(self) {
  {
    "type": self.kind_str,
    "state_key": self.state_key,
    "sender": self.sender,
    "content": Json::object(self.content),
  }
}

///|
pub extend StrippedState with ToJson::{to_json}
