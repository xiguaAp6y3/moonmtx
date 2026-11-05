// Room endpoints: sending events, redaction, create/join/leave/invite,
// typing and receipts. Client-Server API v1.19 "Rooms" and "Events".

///|
/// `PUT /rooms/{roomId}/send/{eventType}/{txnId}`. Retrying with the same
/// `txn_id` is safe: the server returns the original event ID instead of
/// sending again.
pub fn send_request(
  room_id : @ids.RoomId,
  event_type : String,
  txn_id : String,
  content : Json,
) -> Request {
  Request::new(
    Put,
    client_v3([
      Lit("rooms"),
      Var(room_id.as_str()),
      Lit("send"),
      Var(event_type),
      Var(txn_id),
    ]),
    body=content,
  )
}

///|
/// `PUT /rooms/{roomId}/state/{eventType}/{stateKey}`.
pub fn state_request(
  room_id : @ids.RoomId,
  event_type : String,
  content : Json,
  state_key~ : String = "",
) -> Request {
  Request::new(
    Put,
    client_v3([
      Lit("rooms"),
      Var(room_id.as_str()),
      Lit("state"),
      Var(event_type),
      Var(state_key),
    ]),
    body=content,
  )
}

///|
/// `PUT /rooms/{roomId}/redact/{eventId}/{txnId}`.
pub fn redact_request(
  room_id : @ids.RoomId,
  event_id : @ids.EventId,
  txn_id : String,
  reason? : String,
) -> Request {
  Request::new(
    Put,
    client_v3([
      Lit("rooms"),
      Var(room_id.as_str()),
      Lit("redact"),
      Var(event_id.as_str()),
      Var(txn_id),
    ]),
    body=@jsonx.build([("reason", reason.map(Json::string))]),
  )
}

///|
/// The `event_id` returned by send, state and redact requests.
pub fn parse_event_id(resp : Response) -> @ids.EventId raise ApiError {
  decode_ok(resp, m => @jsonx.decode(m, "event_id", @jsonx.root()))
}

///|
pub(all) enum Preset {
  PrivateChat
  TrustedPrivateChat
  PublicChat
} derive(Eq, Debug)

///|
fn Preset::as_str(self : Preset) -> String {
  match self {
    PrivateChat => "private_chat"
    TrustedPrivateChat => "trusted_private_chat"
    PublicChat => "public_chat"
  }
}

///|
/// `POST /createRoom`. `initial_state` entries are `{type, state_key,
/// content}` objects.
pub fn create_room_request(
  name? : String,
  topic? : String,
  preset? : Preset,
  public~ : Bool = false,
  invite~ : Array[@ids.UserId] = [],
  is_direct~ : Bool = false,
  room_alias_name? : String,
  room_version? : String,
  initial_state~ : Array[Json] = [],
) -> Request {
  let body = @jsonx.build([
    ("name", name.map(Json::string)),
    ("topic", topic.map(Json::string)),
    ("preset", preset.map(p => Json::string(p.as_str()))),
    (
      "visibility",
      Some(Json::string(if public { "public" } else { "private" })),
    ),
    (
      "invite",
      if invite.is_empty() {
        None
      } else {
        Some(Json::array(invite.map(u => u.to_json())))
      },
    ),
    ("is_direct", if is_direct { Some(Json::boolean(true)) } else { None }),
    ("room_alias_name", room_alias_name.map(Json::string)),
    ("room_version", room_version.map(Json::string)),
    (
      "initial_state",
      if initial_state.is_empty() {
        None
      } else {
        Some(Json::array(initial_state))
      },
    ),
  ])
  Request::new(Post, client_v3([Lit("createRoom")]), body~)
}

///|
/// The `room_id` returned by create and join requests.
pub fn parse_room_id(resp : Response) -> @ids.RoomId raise ApiError {
  decode_ok(resp, m => @jsonx.decode(m, "room_id", @jsonx.root()))
}

///|
pub(all) enum JoinTarget {
  Id(@ids.RoomId)
  Alias(@ids.RoomAlias)
}

///|
/// `POST /join/{roomIdOrAlias}`. `via` lists servers to join through, needed
/// when joining by ID a room the homeserver is not in.
pub fn join_request(
  target : JoinTarget,
  via~ : Array[@ids.ServerName] = [],
  reason? : String,
) -> Request {
  let t = match target {
    Id(r) => r.as_str()
    Alias(a) => a.to_string()
  }
  Request::new(
    Post,
    client_v3([Lit("join"), Var(t)]),
    query=via.map(s => ("via", s.to_string())),
    body=@jsonx.build([("reason", reason.map(Json::string))]),
  )
}

///|
fn room_action(
  room_id : @ids.RoomId,
  action : String,
  fields : Array[(String, Json?)],
) -> Request {
  Request::new(
    Post,
    client_v3([Lit("rooms"), Var(room_id.as_str()), Lit(action)]),
    body=@jsonx.build(fields),
  )
}

///|
/// `POST /rooms/{roomId}/leave`.
pub fn leave_request(room_id : @ids.RoomId, reason? : String) -> Request {
  room_action(room_id, "leave", [("reason", reason.map(Json::string))])
}

///|
/// `POST /rooms/{roomId}/forget`, after leaving.
pub fn forget_request(room_id : @ids.RoomId) -> Request {
  room_action(room_id, "forget", [])
}

///|
/// `POST /rooms/{roomId}/invite`.
pub fn invite_request(
  room_id : @ids.RoomId,
  user_id : @ids.UserId,
  reason? : String,
) -> Request {
  room_action(room_id, "invite", [
    ("user_id", Some(user_id.to_json())),
    ("reason", reason.map(Json::string)),
  ])
}

///|
/// `PUT /rooms/{roomId}/typing/{userId}`.
pub fn typing_request(
  room_id : @ids.RoomId,
  user_id : @ids.UserId,
  typing : Bool,
  timeout_ms~ : Int32 = 30000,
) -> Request {
  let body : Json = if typing {
    { "typing": true, "timeout": Json::number(timeout_ms.to_double()) }
  } else {
    { "typing": false }
  }
  Request::new(
    Put,
    client_v3([
      Lit("rooms"),
      Var(room_id.as_str()),
      Lit("typing"),
      Var(user_id.to_string()),
    ]),
    body~,
  )
}

///|
/// `POST /rooms/{roomId}/receipt/{receiptType}/{eventId}`, e.g. with
/// `m.read` or `m.read.private`.
pub fn receipt_request(
  room_id : @ids.RoomId,
  event_id : @ids.EventId,
  receipt_type~ : String = "m.read",
  thread_id? : String,
) -> Request {
  Request::new(
    Post,
    client_v3([
      Lit("rooms"),
      Var(room_id.as_str()),
      Lit("receipt"),
      Var(receipt_type),
      Var(event_id.as_str()),
    ]),
    body=@jsonx.build([("thread_id", thread_id.map(Json::string))]),
  )
}
