// An idempotent send queue.
//
// Every message gets a transaction ID when it is queued and keeps it across
// retries, so the homeserver can tell a retry from a new message and never
// posts it twice. Messages to the same room go out one at a time, in order.
// A message is done when its own event comes back through `/sync` with the
// matching `unsigned.transaction_id` (the "local echo"), which may happen
// before or after the send response arrives.
//
// The queue does no I/O and reads no clock: callers pass `now_ms`.

///|
pub(all) enum SendState {
  /// Waiting to be sent.
  Queued
  /// A request is out; wait for its response.
  InFlight
  /// Will be sent again at `at_ms`.
  Retrying(at_ms~ : Int64)
  /// Accepted by the server; waiting for the local echo.
  Sent(@ids.EventId)
  /// Gave up. `retry` queues it again with the same transaction ID.
  Failed(String)
} derive(Eq, Debug)

///|
pub struct Pending {
  txn_id : String
  room_id : @ids.RoomId
  event_type : String
  content : Json
  priv mut state : SendState
  priv mut attempts : Int32
} derive(Eq, Debug)

///|
pub fn Pending::state(self : Pending) -> SendState {
  self.state
}

///|
pub fn Pending::attempts(self : Pending) -> Int32 {
  self.attempts
}

///|
/// What a send response did to a queued message.
pub(all) enum Outcome {
  Sent(@ids.EventId)
  WillRetry(at_ms~ : Int64)
  Failed(String)
  /// The message was already echoed or cancelled; nothing to do.
  Ignored
} derive(Eq, Debug)

///|
pub struct Outbox {
  priv prefix : String
  priv mut counter : Int64
  priv items : Array[Pending]
  priv max_attempts : Int32
  priv base_delay_ms : Int64
  priv max_delay_ms : Int64
}

///|
/// `prefix` must be unique per device and session start, e.g. the device ID
/// plus a start timestamp, because transaction IDs are scoped to the device.
pub fn Outbox::new(
  prefix : String,
  max_attempts~ : Int32 = 5,
  base_delay_ms~ : Int64 = 1000,
  max_delay_ms~ : Int64 = 60000,
) -> Outbox {
  { prefix, counter: 0, items: [], max_attempts, base_delay_ms, max_delay_ms, }
}

///|
/// Queues an event and returns its transaction ID. Use the ID to show a
/// local echo until the real event arrives.
pub fn Outbox::enqueue(
  self : Outbox,
  room_id : @ids.RoomId,
  event_type : String,
  content : Json,
) -> String {
  self.counter += 1
  let txn_id = "\{self.prefix}.\{self.counter}"
  self.items.push({
    txn_id,
    room_id,
    event_type,
    content,
    state: Queued,
    attempts: 0,
  })
  txn_id
}

///|
fn Outbox::find(self : Outbox, txn_id : String) -> Pending? {
  for p in self.items {
    if p.txn_id == txn_id {
      return Some(p)
    }
  }
  None
}

///|
/// Messages not yet echoed, in queue order. `Sent` ones are included until
/// their echo arrives.
pub fn Outbox::pending(self : Outbox) -> Array[Pending] {
  self.items.copy()
}

///|
pub fn Outbox::get(self : Outbox, txn_id : String) -> Pending? {
  self.find(txn_id)
}

///|
/// The next request to send, if any is due at `now_ms`. Only the oldest
/// unfinished message of each room is eligible, so rooms keep their order;
/// failed messages do not block the room.
pub fn Outbox::next_request(
  self : Outbox,
  now_ms : Int64,
) -> (String, @api.Request)? {
  let blocked : Map[@ids.RoomId, Unit] = Map([])
  for p in self.items {
    if blocked.contains(p.room_id) {
      continue
    }
    match p.state {
      Failed(_) | Sent(_) => continue
      InFlight => blocked[p.room_id] = ()
      Retrying(at_ms~) if at_ms > now_ms => blocked[p.room_id] = ()
      Queued | Retrying(_) => {
        p.state = InFlight
        p.attempts += 1
        let req = @api.send_request(
          p.room_id,
          p.event_type,
          p.txn_id,
          p.content,
        )
        return Some((p.txn_id, req))
      }
    }
  }
  None
}

///|
fn Outbox::backoff(self : Outbox, attempts : Int32) -> Int64 {
  let mut d = self.base_delay_ms
  for _ in 1..<attempts {
    d = d * 2
    if d >= self.max_delay_ms {
      return self.max_delay_ms
    }
  }
  d
}

///|
fn is_transient(e : @api.ApiError) -> Bool {
  match e {
    Matrix(m) => m.is_rate_limited() || m.status >= 500
    Http(status~, ..) => status == 408 || status == 429 || status >= 500
    Decode(_) => false
  }
}

///|
fn Outbox::fail_or_retry(
  self : Outbox,
  p : Pending,
  now_ms : Int64,
  transient : Bool,
  delay : Int64?,
  reason : String,
) -> Outcome {
  if transient && p.attempts < self.max_attempts {
    let at_ms = now_ms + delay.unwrap_or(self.backoff(p.attempts))
    p.state = Retrying(at_ms~)
    WillRetry(at_ms~)
  } else {
    p.state = Failed(reason)
    Failed(reason)
  }
}

///|
/// Handles the response to the request returned for `txn_id`.
pub fn Outbox::on_response(
  self : Outbox,
  txn_id : String,
  resp : @api.Response,
  now_ms : Int64,
) -> Outcome {
  guard self.find(txn_id) is Some(p) && p.state is InFlight else {
    return Ignored
  }
  try @api.parse_event_id(resp) catch {
    e =>
      self.fail_or_retry(
        p,
        now_ms,
        is_transient(e),
        @api.retry_delay_ms(resp),
        e.to_string(),
      )
  } noraise {
    event_id => {
      p.state = Sent(event_id)
      Sent(event_id)
    }
  }
}

///|
/// Handles a transport failure (no response) for `txn_id`. It is always
/// retried: the server may or may not have seen the request, and resending
/// with the same transaction ID is safe either way.
pub fn Outbox::on_transport_error(
  self : Outbox,
  txn_id : String,
  reason : String,
  now_ms : Int64,
) -> Outcome {
  guard self.find(txn_id) is Some(p) && p.state is InFlight else {
    return Ignored
  }
  self.fail_or_retry(p, now_ms, true, None, reason)
}

///|
/// Removes messages whose own event arrived in `events` (from `/sync`),
/// matching `unsigned.transaction_id`. Returns the matched transaction IDs
/// with their events.
pub fn Outbox::on_echo(
  self : Outbox,
  room_id : @ids.RoomId,
  events : Array[@events.Event],
) -> Array[(String, @events.Event)] {
  let matched = []
  for e in events {
    guard e.transaction_id() is Some(t) else { continue }
    if self.find(t) is Some(p) && p.room_id == room_id {
      matched.push((t, e))
    }
  }
  if !matched.is_empty() {
    let done : Map[String, Unit] = Map(matched.map(m => (m.0, ())))
    self.items.retain(p => !done.contains(p.txn_id))
  }
  matched
}

///|
/// Queues a failed message again, keeping its transaction ID.
pub fn Outbox::retry(self : Outbox, txn_id : String) -> Bool {
  guard self.find(txn_id) is Some(p) && p.state is Failed(_) else {
    return false
  }
  p.state = Queued
  p.attempts = 0
  true
}

///|
/// Drops a message that has not been accepted by the server yet. A message
/// that is in flight cannot be cancelled: the server may already have it.
pub fn Outbox::cancel(self : Outbox, txn_id : String) -> Bool {
  guard self.find(txn_id) is Some(p) else { return false }
  match p.state {
    Queued | Retrying(_) | Failed(_) => {
      self.items.retain(x => x.txn_id != txn_id)
      true
    }
    InFlight | Sent(_) => false
  }
}
