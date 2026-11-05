// A client session: the sync store, the send queue and the access token,
// driven by whatever HTTP transport the caller has.
//
// Typical loop:
//   1. `prepare(sync_request(...))`, send it, give the response to
//      `on_sync_response`; persist `snapshot()` after each one.
//   2. Between syncs, send everything `next_send` returns and give each
//      response to `on_send_response`.

///|
/// A request ready for an HTTP client: absolute URL, headers with the
/// access token, and body text. Not `Debug`: the headers hold the token.
pub struct Prepared {
  verb : @api.Method
  url : String
  headers : Array[(String, String)]
  body : String?
}

///|
pub struct Client {
  homeserver : String
  priv mut session : @api.Session
  store : @sync.Store
  outbox : @send.Outbox
  priv filter : @sync.Filter
}

///|
/// Creates a client for a logged-in session. `homeserver` is the base URL,
/// e.g. from discovery. Pass a restored store and outbox to resume.
pub fn Client::new(
  homeserver : String,
  session : @api.Session,
  store~ : @sync.Store = @sync.Store::new(),
  outbox? : @send.Outbox,
  filter~ : @sync.Filter = @sync.Filter::new(
    timeline_limit=50,
    lazy_load_members=true,
  ),
) -> Client {
  let outbox = match outbox {
    Some(o) => o
    None => @send.Outbox::new(session.device_id)
  }
  { homeserver, session, store, outbox, filter, }
}

///|
pub fn Client::user_id(self : Client) -> @ids.UserId {
  self.session.user_id
}

///|
pub fn Client::session(self : Client) -> @api.Session {
  self.session
}

///|
/// Replaces the tokens after `/refresh` or a new login on the same device.
pub fn Client::set_session(self : Client, session : @api.Session) -> Unit {
  self.session = session
}

///|
/// Materialises a request against this client's homeserver and token.
pub fn Client::prepare(self : Client, req : @api.Request) -> Prepared {
  {
    verb: req.verb,
    url: req.url(self.homeserver),
    headers: req.headers(access_token=self.session.access_token),
    body: req.body_text(),
  }
}

///|
/// The next `/sync` request, continuing from the stored token. The first
/// sync uses `timeout_ms=0` so it returns at once.
pub fn Client::sync_request(
  self : Client,
  timeout_ms~ : Int32 = 30000,
) -> @api.Request {
  match self.store.since() {
    None => @sync.sync_request(filter=Inline(self.filter), timeout_ms=0)
    Some(since) =>
      @sync.sync_request(since~, filter=Inline(self.filter), timeout_ms~)
  }
}

///|
/// Applies a `/sync` response to the store and completes sent messages
/// whose local echo arrived.
pub fn Client::on_sync_response(
  self : Client,
  resp : @api.Response,
) -> @sync.SyncSummary raise @api.ApiError {
  let parsed = @sync.parse_sync(resp)
  let summary = self.store.apply(parsed)
  for r in summary.rooms {
    ignore(self.outbox.on_echo(r.room_id, r.events))
  }
  summary
}

///|
/// Queues an event for sending and returns its transaction ID.
pub fn Client::send(
  self : Client,
  room_id : @ids.RoomId,
  event_type : String,
  content : Json,
) -> String {
  self.outbox.enqueue(room_id, event_type, content)
}

///|
pub fn Client::send_message(
  self : Client,
  room_id : @ids.RoomId,
  content : @events.MessageContent,
) -> String {
  self.send(room_id, "m.room.message", content.to_json())
}

///|
pub fn Client::send_text(
  self : Client,
  room_id : @ids.RoomId,
  body : String,
) -> String {
  self.send_message(room_id, @events.text(body))
}

///|
/// The next send request due at `now_ms`, prepared for the transport.
pub fn Client::next_send(self : Client, now_ms : Int64) -> (String, Prepared)? {
  self.outbox.next_request(now_ms).map(r => (r.0, self.prepare(r.1)))
}

///|
pub fn Client::on_send_response(
  self : Client,
  txn_id : String,
  resp : @api.Response,
  now_ms : Int64,
) -> @send.Outcome {
  self.outbox.on_response(txn_id, resp, now_ms)
}

///|
/// Everything needed to resume, except the access token: the sync store
/// (with its token) and the send queue. Persist it with one atomic write.
pub fn Client::snapshot(self : Client) -> Json {
  { "store": self.store.to_json(), "outbox": self.outbox.to_json() }
}

///|
pub(all) suberror RestoreError {
  RestoreError(String)
} derive(Debug)

///|
/// Restores a client from `snapshot()` output and a stored session.
pub fn Client::restore(
  homeserver : String,
  session : @api.Session,
  snapshot : Json,
  filter? : @sync.Filter,
) -> Client raise RestoreError {
  guard snapshot is Object(m) &&
    m.get("store") is Some(store_json) &&
    m.get("outbox") is Some(outbox_json) else {
    raise RestoreError("snapshot must have store and outbox")
  }
  let store = @sync.Store::from_json(store_json) catch {
    e => raise RestoreError(e.to_string())
  }
  let outbox = @send.Outbox::from_json(outbox_json) catch {
    e => raise RestoreError(e.to_string())
  }
  match filter {
    Some(f) => Client::new(homeserver, session, store~, outbox~, filter=f)
    None => Client::new(homeserver, session, store~, outbox~)
  }
}
