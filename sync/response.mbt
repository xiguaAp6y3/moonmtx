// `GET /sync` response parsing.
//
// One malformed event or room must not make a whole sync batch unusable:
// such entries are skipped and reported in `SyncResponse::invalid`. A
// response without `next_batch` is rejected, since the sync cannot continue.

///|
pub struct Timeline {
  events : Array[@events.Event]
  /// More events happened since the previous sync than are listed here.
  limited : Bool
  /// Token to paginate backwards from the start of `events`.
  prev_batch : String?
} derive(Eq, Debug)

///|
/// `summary` of a joined room. Fields are only sent when they change.
pub struct RoomSummary {
  heroes : Array[String]?
  joined_member_count : Int64?
  invited_member_count : Int64?
} derive(Eq, Debug)

///|
pub struct JoinedRoom {
  room_id : @ids.RoomId
  summary : RoomSummary
  /// State up to the start of `timeline`, not including it.
  state : Array[@events.Event]
  timeline : Timeline
  /// Ephemeral events (typing, receipts) as raw `{type, content}` objects.
  ephemeral : Array[Json]
  account_data : Array[Json]
  notification_count : Int64?
  highlight_count : Int64?
} derive(Eq, Debug)

///|
pub struct InvitedRoom {
  room_id : @ids.RoomId
  invite_state : Array[@events.StrippedState]
} derive(Eq, Debug)

///|
pub struct KnockedRoom {
  room_id : @ids.RoomId
  knock_state : Array[@events.StrippedState]
} derive(Eq, Debug)

///|
pub struct LeftRoom {
  room_id : @ids.RoomId
  state : Array[@events.Event]
  timeline : Timeline
  account_data : Array[Json]
} derive(Eq, Debug)

///|
pub struct SyncResponse {
  next_batch : String
  join : Array[JoinedRoom]
  invite : Array[InvitedRoom]
  knock : Array[KnockedRoom]
  leave : Array[LeftRoom]
  /// Global account data as raw `{type, content}` objects.
  account_data : Array[Json]
  /// Entries that were skipped, as `path: reason`.
  invalid : Array[String]
} derive(Eq, Debug)

///|
priv struct Ctx {
  invalid : Array[String]
}

///|
fn Ctx::skip(self : Ctx, path : @json.JsonPath, msg : String) -> Unit {
  self.invalid.push("\{path}: \{msg}")
}

///|
fn Ctx::list(
  self : Ctx,
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[Json] {
  try @jsonx.array(m, key, path) catch {
    e => {
      self.invalid.push(e.to_string())
      []
    }
  } noraise {
    a => a
  }
}

///|
/// Decodes each element with `f`, skipping and recording failures.
fn[T] Ctx::each(
  self : Ctx,
  items : Array[Json],
  path : @json.JsonPath,
  f : (Json, @json.JsonPath) -> T raise @json.JsonDecodeError,
) -> Array[T] {
  let out = []
  for i, item in items {
    let p = path.add_index(i)
    try f(item, p) catch {
      @json.JsonDecodeError((ep, msg)) => self.skip(ep, msg)
    } noraise {
      v => out.push(v)
    }
  }
  out
}

///|
/// `{ "events": [...] }` sections.
fn Ctx::section(
  self : Ctx,
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[Json] {
  match m.get(key) {
    None | Some(Null) => []
    Some(Object(o)) => self.list(o, "events", path.add_key(key))
    Some(_) => {
      self.skip(path.add_key(key), "expected an object")
      []
    }
  }
}

///|
fn Ctx::events(
  self : Ctx,
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[@events.Event] {
  self.each(
    self.section(m, key, path),
    path.add_key(key).add_key("events"),
    @events.Event::decode,
  )
}

///|
fn Ctx::stripped(
  self : Ctx,
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[@events.StrippedState] {
  self.each(self.section(m, key, path), path.add_key(key).add_key("events"), (
    j,
    p,
  ) => @json.from_json(j, path=p))
}

///|
fn Ctx::raw_events(
  self : Ctx,
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[Json] {
  self.each(self.section(m, key, path), path.add_key(key).add_key("events"), (
    j,
    p,
  ) => {
    let o = @jsonx.object(j, p)
    ignore(@jsonx.string(o, "type", p))
    j
  })
}

///|
fn Ctx::timeline(
  self : Ctx,
  m : Map[String, Json],
  path : @json.JsonPath,
) -> Timeline raise @json.JsonDecodeError {
  guard @jsonx.opt_object(m, "timeline", path) is Some(t) else {
    return { events: [], limited: false, prev_batch: None, }
  }
  let p = path.add_key("timeline")
  {
    events: self.each(
      self.list(t, "events", p),
      p.add_key("events"),
      @events.Event::decode,
    ),
    limited: @jsonx.opt_bool(t, "limited", p).unwrap_or(false),
    prev_batch: @jsonx.opt_string(t, "prev_batch", p),
  }
}

///|
fn decode_summary(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> RoomSummary raise @json.JsonDecodeError {
  guard @jsonx.opt_object(m, "summary", path) is Some(s) else {
    return {
      heroes: None,
      joined_member_count: None,
      invited_member_count: None,
    }
  }
  let p = path.add_key("summary")
  {
    heroes: @jsonx.opt_decode(s, "m.heroes", p),
    joined_member_count: @jsonx.opt_int(s, "m.joined_member_count", p),
    invited_member_count: @jsonx.opt_int(s, "m.invited_member_count", p),
  }
}

///|
/// Iterates `rooms.<key>`, parsing room IDs and skipping bad entries.
fn[T] Ctx::rooms(
  self : Ctx,
  rooms : Map[String, Json],
  key : String,
  path : @json.JsonPath,
  f : (@ids.RoomId, Map[String, Json], @json.JsonPath) -> T raise @json.JsonDecodeError,
) -> Array[T] {
  let out = []
  let p = path.add_key(key)
  guard rooms.get(key) is Some(Object(section)) else {
    if rooms.get(key) is Some(v) && v != Json::null() {
      self.skip(p, "expected an object")
    }
    return out
  }
  for id, body in section {
    let rp = p.add_key(id)
    let room_id = @ids.RoomId::parse(id) catch {
      e => {
        self.skip(rp, e.to_string())
        continue
      }
    }
    try f(room_id, @jsonx.object(body, rp), rp) catch {
      @json.JsonDecodeError((ep, msg)) => self.skip(ep, msg)
    } noraise {
      v => out.push(v)
    }
  }
  out
}

///|
fn notification_counts(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> (Int64?, Int64?) raise @json.JsonDecodeError {
  guard @jsonx.opt_object(m, "unread_notifications", path) is Some(u) else {
    return (None, None)
  }
  let p = path.add_key("unread_notifications")
  (
    @jsonx.opt_int(u, "notification_count", p),
    @jsonx.opt_int(u, "highlight_count", p),
  )
}

///|
pub fn SyncResponse::decode(
  m : Map[String, Json],
) -> SyncResponse raise @json.JsonDecodeError {
  let root = @jsonx.root()
  let ctx = { invalid: [], }
  let next_batch = @jsonx.string(m, "next_batch", root)
  let rooms = @jsonx.opt_object(m, "rooms", root).unwrap_or(Map([]))
  let rp = root.add_key("rooms")
  let join = ctx.rooms(rooms, "join", rp, (room_id, r, p) => {
    let (notification_count, highlight_count) = notification_counts(r, p)
    {
      room_id,
      summary: decode_summary(r, p),
      state: ctx.events(r, "state", p),
      timeline: ctx.timeline(r, p),
      ephemeral: ctx.raw_events(r, "ephemeral", p),
      account_data: ctx.raw_events(r, "account_data", p),
      notification_count,
      highlight_count,
    }
  })
  let invite = ctx.rooms(rooms, "invite", rp, (room_id, r, p) => {
    room_id,
    invite_state: ctx.stripped(r, "invite_state", p),
  })
  let knock = ctx.rooms(rooms, "knock", rp, (room_id, r, p) => {
    room_id,
    knock_state: ctx.stripped(r, "knock_state", p),
  })
  let leave = ctx.rooms(rooms, "leave", rp, (room_id, r, p) => {
    room_id,
    state: ctx.events(r, "state", p),
    timeline: ctx.timeline(r, p),
    account_data: ctx.raw_events(r, "account_data", p),
  })
  {
    next_batch,
    join,
    invite,
    knock,
    leave,
    account_data: ctx.raw_events(m, "account_data", root),
    invalid: ctx.invalid,
  }
}

///|
pub fn parse_sync(resp : @api.Response) -> SyncResponse raise @api.ApiError {
  @api.decode_ok(resp, SyncResponse::decode)
}
