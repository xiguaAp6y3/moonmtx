// State event contents used by the room state store.

///|
pub(all) enum Membership {
  Join
  Invite
  Leave
  Ban
  Knock
  Other(String)
} derive(Eq, Debug)

///|
pub fn Membership::parse(s : String) -> Membership {
  match s {
    "join" => Join
    "invite" => Invite
    "leave" => Leave
    "ban" => Ban
    "knock" => Knock
    other => Other(other)
  }
}

///|
pub fn Membership::as_str(self : Membership) -> String {
  match self {
    Join => "join"
    Invite => "invite"
    Leave => "leave"
    Ban => "ban"
    Knock => "knock"
    Other(s) => s
  }
}

///|
/// Content of `m.room.member`.
pub struct MemberContent {
  membership : Membership
  displayname : String?
  avatar_url : String?
  reason : String?
  is_direct : Bool
} derive(Eq, Debug)

///|
pub fn MemberContent::decode(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> MemberContent raise @json.JsonDecodeError {
  {
    membership: Membership::parse(@jsonx.string(m, "membership", path)),
    displayname: @jsonx.opt_string(m, "displayname", path),
    avatar_url: @jsonx.opt_string(m, "avatar_url", path),
    reason: @jsonx.opt_string(m, "reason", path),
    is_direct: @jsonx.opt_bool(m, "is_direct", path).unwrap_or(false),
  }
}

///|
/// Reads a power level, accepting the string form that room versions before
/// 10 allowed.
fn level(
  m : Map[String, Json],
  key : String,
  default : Int64,
  path : @json.JsonPath,
) -> Int64 raise @json.JsonDecodeError {
  match m.get(key) {
    None | Some(Null) => default
    Some(Number(d, ..)) => d.to_int64()
    Some(String(s)) =>
      @string.parse_int64(s) catch {
        _ => @jsonx.fail(path.add_key(key), "invalid power level")
      }
    Some(_) => @jsonx.fail(path.add_key(key), "invalid power level")
  }
}

///|
fn levels(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Map[String, Int64] raise @json.JsonDecodeError {
  let out : Map[String, Int64] = Map([])
  guard @jsonx.opt_object(m, key, path) is Some(o) else { return out }
  let p = path.add_key(key)
  for k, _ in o {
    out[k] = level(o, k, 0, p)
  }
  out
}

///|
/// Content of `m.room.power_levels`, with the spec defaults for missing
/// keys.
pub struct PowerLevels {
  ban : Int64
  kick : Int64
  invite : Int64
  redact : Int64
  events_default : Int64
  state_default : Int64
  users_default : Int64
  events : Map[String, Int64]
  users : Map[String, Int64]
  notifications : Map[String, Int64]
} derive(Eq, Debug)

///|
pub fn PowerLevels::decode(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> PowerLevels raise @json.JsonDecodeError {
  let notifications = levels(m, "notifications", path)
  if !notifications.contains("room") {
    notifications["room"] = 50
  }
  {
    ban: level(m, "ban", 50, path),
    kick: level(m, "kick", 50, path),
    invite: level(m, "invite", 0, path),
    redact: level(m, "redact", 50, path),
    events_default: level(m, "events_default", 0, path),
    state_default: level(m, "state_default", 50, path),
    users_default: level(m, "users_default", 0, path),
    events: levels(m, "events", path),
    users: levels(m, "users", path),
    notifications,
  }
}

///|
/// Levels that apply when a room has no `m.room.power_levels` event: the
/// creator has 100, everyone else 0, and every action needs 0.
pub fn PowerLevels::absent(creator : String?) -> PowerLevels {
  let users : Map[String, Int64] = Map([])
  if creator is Some(c) {
    users[c] = 100
  }
  {
    ban: 50,
    kick: 50,
    invite: 0,
    redact: 50,
    events_default: 0,
    state_default: 0,
    users_default: 0,
    events: Map([]),
    users,
    notifications: { "room": 50 },
  }
}

///|
pub fn PowerLevels::user_level(self : PowerLevels, user_id : String) -> Int64 {
  self.users.get(user_id).unwrap_or(self.users_default)
}

///|
/// The level needed to send an event of `event_type`.
pub fn PowerLevels::required_for(
  self : PowerLevels,
  event_type : String,
  is_state~ : Bool,
) -> Int64 {
  match self.events.get(event_type) {
    Some(l) => l
    None => if is_state { self.state_default } else { self.events_default }
  }
}

///|
pub fn PowerLevels::can_send(
  self : PowerLevels,
  user_id : String,
  event_type : String,
  is_state~ : Bool,
) -> Bool {
  self.user_level(user_id) >= self.required_for(event_type, is_state~)
}

///|
/// A typed view of an event's content.
pub(all) enum EventKind {
  Message(MessageContent)
  Member(MemberContent)
  Name(String)
  Topic(String)
  PowerLevels(PowerLevels)
  Reaction(Relation)
  Redaction
  /// A type this library does not model, or content that did not decode.
  Unknown
} derive(Eq, Debug)

///|
fn decode_kind(e : Event) -> EventKind raise @json.JsonDecodeError {
  let c = e.content
  let p = @jsonx.root().add_key("content")
  match e.kind_str {
    "m.room.message" => Message(MessageContent::decode(c, p))
    "m.room.member" if e.is_state() => Member(MemberContent::decode(c, p))
    "m.room.name" if e.is_state() =>
      Name(@jsonx.opt_string(c, "name", p).unwrap_or(""))
    "m.room.topic" if e.is_state() =>
      Topic(@jsonx.opt_string(c, "topic", p).unwrap_or(""))
    "m.room.power_levels" if e.is_state() =>
      PowerLevels(PowerLevels::decode(c, p))
    "m.reaction" =>
      match Relation::from_content(c) {
        Some(Annotation(_, ..) as r) => Reaction(r)
        _ => Unknown
      }
    "m.room.redaction" => Redaction
    _ => Unknown
  }
}

///|
/// Decodes the content by event type. Redacted events, unknown types and
/// malformed content give `Unknown`; the raw JSON is still on the event.
pub fn Event::kind(self : Event) -> EventKind {
  decode_kind(self) catch {
    _ => Unknown
  }
}
