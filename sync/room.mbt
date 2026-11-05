// Per-room state kept by the store.
//
// The timeline is a list of chunks. Each chunk is a contiguous run of events
// together with the pagination token that leads to the events before it.
// When a sync timeline is `limited`, the new chunk is marked `gap_before`:
// events are missing between it and the previous chunk until a backfill
// closes the gap. Chunks are only ever dropped whole, so every remaining
// chunk keeps a valid token for paginating further back.

///|
priv struct Chunk {
  /// Token to paginate backwards from the first event of this chunk, or
  /// `None` when the start of the room has been reached.
  mut prev_batch : String?
  /// Events are missing between the previous chunk and this one.
  mut gap_before : Bool
  events : Array[@events.Event]
}

///|
pub(all) enum TimelineItem {
  Event(@events.Event)
  /// Missing events; fill with `Store::fill_gap` using this token.
  Gap(String)
} derive(Eq, Debug)

///|
pub struct Room {
  room_id : @ids.RoomId
  priv mut membership : @events.Membership
  /// `type -> state_key -> event`.
  priv state : Map[String, Map[String, @events.Event]]
  priv chunks : Array[Chunk]
  /// Recently seen event IDs, oldest first, for de-duplication.
  priv recent : Array[String]
  priv seen : Map[String, Unit]
  priv account_data : Map[String, Json]
  priv ephemeral : Map[String, Json]
  priv mut heroes : Array[String]
  priv mut joined_count : Int64?
  priv mut invited_count : Int64?
  priv mut notification_count : Int64
  priv mut highlight_count : Int64
}

///|
/// How many event IDs a room remembers for de-duplication.
let recent_cap : Int32 = 1024

///|
fn Room::new(room_id : @ids.RoomId) -> Room {
  {
    room_id,
    membership: Join,
    state: Map([]),
    chunks: [],
    recent: [],
    seen: Map([]),
    account_data: Map([]),
    ephemeral: Map([]),
    heroes: [],
    joined_count: None,
    invited_count: None,
    notification_count: 0,
    highlight_count: 0,
  }
}

///|
fn Room::has_seen(self : Room, id : @ids.EventId) -> Bool {
  self.seen.contains(id.as_str())
}

///|
fn Room::mark_seen(self : Room, id : @ids.EventId) -> Unit {
  let s = id.as_str()
  if self.seen.contains(s) {
    return
  }
  self.seen[s] = ()
  self.recent.push(s)
  if self.recent.length() > recent_cap {
    let drop = self.recent.length() - recent_cap
    for old in self.recent.drain(0, drop) {
      self.seen.remove(old)
    }
  }
}

///|
fn Room::set_state(self : Room, e : @events.Event) -> Unit {
  guard e.state_key is Some(key) else { return }
  self.state.get_or_init(e.kind_str, () => Map([]))[key] = e
}

///|
/// Applies a redaction to stored copies of the target event.
fn Room::apply_redaction(self : Room, redaction : @events.Event) -> Unit {
  guard redaction.redacts() is Some(target) else { return }
  for chunk in self.chunks {
    for i, e in chunk.events {
      if e.event_id == target {
        chunk.events[i] = e.redact(redaction)
      }
    }
  }
  for _, by_key in self.state {
    for key, e in by_key {
      if e.event_id == target {
        by_key[key] = e.redact(redaction)
      }
    }
  }
}

///|
pub fn Room::membership(self : Room) -> @events.Membership {
  self.membership
}

///|
/// The current state event of `event_type` with `state_key`.
pub fn Room::state_event(
  self : Room,
  event_type : String,
  state_key~ : String = "",
) -> @events.Event? {
  self.state.get(event_type).bind(m => m.get(state_key))
}

///|
/// All current state events of `event_type`, by state key.
pub fn Room::state_events(
  self : Room,
  event_type : String,
) -> Map[String, @events.Event] {
  self.state.get(event_type).unwrap_or(Map([]))
}

///|
pub fn Room::member_content(
  self : Room,
  user_id : String,
) -> @events.MemberContent? {
  match
    self.state_event("m.room.member", state_key=user_id).map(e => e.kind()) {
    Some(Member(m)) => Some(m)
    _ => None
  }
}

///|
/// User IDs with the given membership, in no particular order.
pub fn Room::members_with(
  self : Room,
  membership : @events.Membership,
) -> Array[String] {
  let out = []
  for user, e in self.state_events("m.room.member") {
    if e.kind() is Member(m) && m.membership == membership {
      out.push(user)
    }
  }
  out
}

///|
pub fn Room::power_levels(self : Room) -> @events.PowerLevels {
  match self.state_event("m.room.power_levels").map(e => e.kind()) {
    Some(PowerLevels(pl)) => pl
    _ => {
      let creator = self.state_event("m.room.create").map(e => e.sender)
      @events.PowerLevels::absent(creator)
    }
  }
}

///|
fn non_empty_string(content : Map[String, Json], key : String) -> String? {
  match content.get(key) {
    Some(String(s)) if !s.is_empty() => Some(s)
    _ => None
  }
}

///|
/// The name to show for a member, following the spec's "Calculating the
/// display name for a user": the display name, or the user ID, with the
/// user ID appended when another member uses the same display name.
pub fn Room::member_name(self : Room, user_id : String) -> String {
  guard self.member_content(user_id) is Some({ displayname: Some(name), .. }) &&
    !name.is_empty() else {
    return user_id
  }
  for other, e in self.state_events("m.room.member") {
    if other != user_id &&
      e.kind() is Member({ displayname: Some(n), membership, .. }) &&
      n == name &&
      (membership == Join || membership == Invite) {
      return "\{name} (\{user_id})"
    }
  }
  name
}

///|
fn join_names(names : Array[String], others : Int64) -> String {
  let n = names.length()
  if others > 0 {
    let s = if others == 1 { "other" } else { "others" }
    return names.join(", ") + " and \{others} \{s}"
  }
  match n {
    0 => ""
    1 => names[0]
    _ => names[:n - 1].join(", ") + " and " + names[n - 1]
  }
}

///|
/// The room name to show, following the spec's "Calculating the display
/// name for a room": `m.room.name`, then `m.room.canonical_alias`, then
/// names of the heroes. `me` is the current user, excluded from heroes.
pub fn Room::display_name(self : Room, me : String) -> String {
  if self.state_event("m.room.name") is Some(e) &&
    non_empty_string(e.content, "name") is Some(n) {
    return n
  }
  if self.state_event("m.room.canonical_alias") is Some(e) &&
    non_empty_string(e.content, "alias") is Some(a) {
    return a
  }
  let heroes = if self.heroes.is_empty() {
    let hs = self.members_with(Join)
    hs.append(self.members_with(Invite))
    hs.sort_by((a, b) => a.lexical_compare(b))
    let hs = hs.filter(u => u != me)
    hs.truncate(5)
    hs
  } else {
    self.heroes.filter(u => u != me)
  }
  let joined = self.joined_count.unwrap_or(
    self.members_with(Join).length().to_int64(),
  )
  let invited = self.invited_count.unwrap_or(
    self.members_with(Invite).length().to_int64(),
  )
  let names = heroes.map(u => self.member_name(u))
  if joined + invited <= 1 {
    if names.is_empty() {
      return "Empty Room"
    }
    return "Empty Room (was \{join_names(names, 0)})"
  }
  let others = joined + invited - 1 - heroes.length().to_int64()
  join_names(names, if others > 0 { others } else { 0 })
}

///|
/// The stored timeline, oldest first, with gap markers.
pub fn Room::timeline(self : Room) -> Array[TimelineItem] {
  let out = []
  for i, c in self.chunks {
    if c.gap_before && i > 0 && c.prev_batch is Some(t) {
      out.push(Gap(t))
    }
    for e in c.events {
      out.push(Event(e))
    }
  }
  out
}

///|
/// The stored timeline events, oldest first, without gap markers.
pub fn Room::events(self : Room) -> Array[@events.Event] {
  let out = []
  for c in self.chunks {
    out.append(c.events)
  }
  out
}

///|
/// Tokens of the gaps in the stored timeline, oldest first.
pub fn Room::gaps(self : Room) -> Array[String] {
  let out = []
  for i, c in self.chunks {
    if c.gap_before && i > 0 && c.prev_batch is Some(t) {
      out.push(t)
    }
  }
  out
}

///|
/// Token for loading history before the stored timeline, or `None` when the
/// start of the room has been reached.
pub fn Room::back_token(self : Room) -> String? {
  self.chunks.get(0).bind(c => c.prev_batch)
}

///|
/// Users currently typing, from the latest `m.typing` ephemeral event.
pub fn Room::typing(self : Room) -> Array[String] {
  guard self.ephemeral.get("m.typing") is Some(Object(c)) &&
    c.get("user_ids") is Some(Array(ids)) else {
    return []
  }
  let out = []
  for id in ids {
    if id is String(s) {
      out.push(s)
    }
  }
  out
}

///|
/// The latest ephemeral event content of `event_type`, e.g. `m.receipt`.
pub fn Room::ephemeral(self : Room, event_type : String) -> Json? {
  self.ephemeral.get(event_type)
}

///|
pub fn Room::account_data(self : Room, event_type : String) -> Json? {
  self.account_data.get(event_type)
}

///|
/// `(notification_count, highlight_count)` from the latest sync.
pub fn Room::unread(self : Room) -> (Int64, Int64) {
  (self.notification_count, self.highlight_count)
}
