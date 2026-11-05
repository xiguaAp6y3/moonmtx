// Message events: `m.room.message`, `m.reaction` and `m.relates_to`.

///|
pub(all) enum MsgType {
  Text
  Notice
  Emote
  Image
  File
  Audio
  Video
  Location
  /// Any other `msgtype`, kept verbatim.
  Other(String)
} derive(Eq, Debug)

///|
pub fn MsgType::parse(s : String) -> MsgType {
  match s {
    "m.text" => Text
    "m.notice" => Notice
    "m.emote" => Emote
    "m.image" => Image
    "m.file" => File
    "m.audio" => Audio
    "m.video" => Video
    "m.location" => Location
    other => Other(other)
  }
}

///|
pub fn MsgType::as_str(self : MsgType) -> String {
  match self {
    Text => "m.text"
    Notice => "m.notice"
    Emote => "m.emote"
    Image => "m.image"
    File => "m.file"
    Audio => "m.audio"
    Video => "m.video"
    Location => "m.location"
    Other(s) => s
  }
}

///|
/// The `m.relates_to` of an event.
pub(all) enum Relation {
  /// A rich reply (`m.in_reply_to`) outside a thread.
  Reply(@ids.EventId)
  /// An edit (`rel_type: m.replace`) of the given event.
  Replace(@ids.EventId)
  /// An annotation such as a reaction (`rel_type: m.annotation`).
  Annotation(@ids.EventId, key~ : String)
  /// A thread message (`rel_type: m.thread`). `reply_to` is the event the
  /// message replies to inside the thread, unless it is a fallback reply.
  Thread(root~ : @ids.EventId, reply_to~ : @ids.EventId?)
  /// A `rel_type` this library does not model.
  Unknown(Map[String, Json])
} derive(Eq, Debug)

///|
fn opt_event_id(m : Map[String, Json], key : String) -> @ids.EventId? {
  guard m.get(key) is Some(String(s)) else { return None }
  try @ids.EventId::parse(s) catch {
    _ => None
  } noraise {
    e => Some(e)
  }
}

///|
fn in_reply_to(m : Map[String, Json]) -> @ids.EventId? {
  guard m.get("m.in_reply_to") is Some(Object(r)) else { return None }
  opt_event_id(r, "event_id")
}

///|
/// Reads `m.relates_to` from an event content object.
pub fn Relation::from_content(content : Map[String, Json]) -> Relation? {
  guard content.get("m.relates_to") is Some(Object(r)) else { return None }
  match r.get("rel_type") {
    Some(String("m.replace")) =>
      match opt_event_id(r, "event_id") {
        Some(e) => Some(Replace(e))
        None => Some(Unknown(r))
      }
    Some(String("m.annotation")) =>
      match (opt_event_id(r, "event_id"), r.get("key")) {
        (Some(e), Some(String(key))) => Some(Annotation(e, key~))
        _ => Some(Unknown(r))
      }
    Some(String("m.thread")) =>
      match opt_event_id(r, "event_id") {
        Some(root) => {
          let fallback = r.get("is_falling_back") is Some(True)
          let reply_to = if fallback { None } else { in_reply_to(r) }
          Some(Thread(root~, reply_to~))
        }
        None => Some(Unknown(r))
      }
    Some(_) => Some(Unknown(r))
    None =>
      match in_reply_to(r) {
        Some(e) => Some(Reply(e))
        None => None
      }
  }
}

///|
pub impl ToJson for Relation with fn to_json(self) {
  match self {
    Reply(e) => { "m.in_reply_to": { "event_id": e.to_json() } }
    Replace(e) => { "rel_type": "m.replace", "event_id": e.to_json() }
    Annotation(e, key~) =>
      { "rel_type": "m.annotation", "event_id": e.to_json(), "key": key }
    Thread(root~, reply_to~) =>
      match reply_to {
        Some(r) =>
          {
            "rel_type": "m.thread",
            "event_id": root.to_json(),
            "is_falling_back": false,
            "m.in_reply_to": { "event_id": r.to_json() },
          }
        None => { "rel_type": "m.thread", "event_id": root.to_json() }
      }
    Unknown(m) => Json::object(m)
  }
}

///|
/// The content of an `m.room.message` event.
pub struct MessageContent {
  msgtype : MsgType
  body : String
  /// `format`, e.g. `org.matrix.custom.html`, with `formatted_body`.
  format : String?
  formatted_body : String?
  relation : Relation?
  /// For edits: the replacement content (`m.new_content`).
  new_content : Map[String, Json]?
  /// The full content object, for media fields and anything else.
  raw : Map[String, Json]
} derive(Eq, Debug)

///|
pub fn MessageContent::decode(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> MessageContent raise @json.JsonDecodeError {
  {
    msgtype: MsgType::parse(@jsonx.string(m, "msgtype", path)),
    body: @jsonx.string(m, "body", path),
    format: @jsonx.opt_string(m, "format", path),
    formatted_body: @jsonx.opt_string(m, "formatted_body", path),
    relation: Relation::from_content(m),
    new_content: @jsonx.opt_object(m, "m.new_content", path),
    raw: m,
  }
}

///|
/// For an edit, the replacement message; `None` otherwise or if it does not
/// decode.
pub fn MessageContent::replacement(self : MessageContent) -> MessageContent? {
  guard self.relation is Some(Replace(_)) else { return None }
  guard self.new_content is Some(nc) else { return None }
  try MessageContent::decode(nc, @jsonx.root()) catch {
    _ => None
  } noraise {
    c => Some(c)
  }
}

///|
/// Content for a new message. `html` sets an HTML `formatted_body`.
pub fn MessageContent::new(
  msgtype : MsgType,
  body : String,
  html? : String,
  relation? : Relation,
) -> MessageContent {
  let (format, formatted_body) = match html {
    Some(h) => (Some("org.matrix.custom.html"), Some(h))
    None => (None, None)
  }
  {
    msgtype,
    body,
    format,
    formatted_body,
    relation,
    new_content: None,
    raw: Map([]),
  }
}

///|
pub fn text(body : String, html? : String) -> MessageContent {
  MessageContent::new(Text, body, html?)
}

///|
pub fn notice(body : String, html? : String) -> MessageContent {
  MessageContent::new(Notice, body, html?)
}

///|
pub fn emote(body : String, html? : String) -> MessageContent {
  MessageContent::new(Emote, body, html?)
}

///|
/// Makes this message a reply to `event_id`.
pub fn MessageContent::reply_to(
  self : MessageContent,
  event_id : @ids.EventId,
) -> MessageContent {
  { ..self, relation: Some(Reply(event_id)), }
}

///|
/// Makes this message part of the thread rooted at `root`.
pub fn MessageContent::in_thread(
  self : MessageContent,
  root : @ids.EventId,
  reply_to? : @ids.EventId,
) -> MessageContent {
  { ..self, relation: Some(Thread(root~, reply_to~)), }
}

///|
fn MessageContent::base_fields(self : MessageContent) -> Map[String, Json] {
  let m = self.raw.copy()
  m["msgtype"] = Json::string(self.msgtype.as_str())
  m["body"] = Json::string(self.body)
  match (self.format, self.formatted_body) {
    (Some(f), Some(fb)) => {
      m["format"] = Json::string(f)
      m["formatted_body"] = Json::string(fb)
    }
    _ => {
      m.remove("format")
      m.remove("formatted_body")
    }
  }
  m
}

///|
/// Content of a new message, ready to send. Fields of `raw` that the typed
/// fields do not cover are kept.
pub impl ToJson for MessageContent with fn to_json(self) {
  let m = self.base_fields()
  match self.relation {
    Some(r) => m["m.relates_to"] = r.to_json()
    None => m.remove("m.relates_to")
  }
  match self.new_content {
    Some(nc) => m["m.new_content"] = Json::object(nc)
    None => m.remove("m.new_content")
  }
  Json::object(m)
}

///|
/// Content that edits `original` so that it reads as `replacement`.
/// The fallback `body` is prefixed with `* ` for clients without edit
/// support. The replacement must not carry its own relation.
pub fn edit(original : @ids.EventId, replacement : MessageContent) -> Json {
  let new_content = replacement.base_fields()
  new_content.remove("m.relates_to")
  new_content.remove("m.new_content")
  let m = new_content.copy()
  m["body"] = Json::string("* " + replacement.body)
  if replacement.formatted_body is Some(fb) {
    m["formatted_body"] = Json::string("* " + fb)
  }
  m["m.new_content"] = Json::object(new_content)
  m["m.relates_to"] = Replace(original).to_json()
  Json::object(m)
}

///|
/// Content of an `m.reaction` event.
pub fn reaction(target : @ids.EventId, key : String) -> Json {
  { "m.relates_to": Annotation(target, key~).to_json() }
}

///|
pub extend Relation with ToJson::{to_json}

///|
pub extend MessageContent with ToJson::{to_json}
