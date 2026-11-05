// Native HTTP transport for the sans-IO client, using moonbitlang/async.
//
// This package is the only one that performs I/O; the rest of moonmtx runs
// on every target and can be driven by any other HTTP client instead.

///|
fn method_of(m : @api.Method) -> @http.RequestMethod {
  match m {
    Get => Get
    Post => Post
    Put => Put
    Delete => Delete
  }
}

///|
fn parse_retry_after(v : String?) -> Int32? {
  guard v is Some(s) && !s.is_empty() else { return None }
  let mut n = 0
  for c in s {
    if c < '0' || c > '9' {
      // HTTP-date form: not supported, fall back to the body field.
      return None
    }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  Some(n)
}

///|
async fn send_raw(
  verb : @api.Method,
  url : String,
  header_list : Array[(String, String)],
  body : String?,
) -> @api.Response {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  for h in header_list {
    headers[h.0] = h.1
  }
  let (resp, data) = match body {
    None if verb is Get => @http.get(url, headers~)
    None => @http.request(url, method_of(verb), headers, "")
    Some(b) => @http.request(url, method_of(verb), headers, b)
  }
  let retry_after_s = parse_retry_after(resp.headers.get("retry-after"))
  @api.Response::new(resp.code, data.text(), retry_after_s?)
}

///|
/// Sends a prepared request and reads the whole response.
pub async fn perform(p : @client.Prepared) -> @api.Response {
  send_raw(p.verb, p.url, p.headers, p.body)
}

///|
/// Sends a request without a `Client`, e.g. for discovery or login.
pub async fn request(
  base_url : String,
  req : @api.Request,
  access_token? : String,
) -> @api.Response {
  send_raw(
    req.verb,
    req.url(base_url),
    req.headers(access_token?),
    req.body_text(),
  )
}

///|
/// Sends every queued message that is due. Transport failures are handed
/// to the send queue, which schedules a retry.
pub async fn flush_sends(c : @client.Client) -> Unit {
  while c.next_send(@async.now()) is Some((txn_id, req)) {
    let resp = perform(req) catch {
      e => {
        ignore(c.outbox.on_transport_error(txn_id, e.to_string(), @async.now()))
        continue
      }
    }
    ignore(c.on_send_response(txn_id, resp, @async.now()))
  }
}

///|
/// Runs the sync loop: sends due messages, long-polls `/sync`, applies the
/// response, calls `persist` with the snapshot, then `on_sync`. Stops when
/// `on_sync` returns `false`. Rate limits and transport errors back off and
/// retry; other API errors (e.g. an invalid token) end the loop.
pub async fn run_sync_loop(
  c : @client.Client,
  on_sync : async (@sync.SyncSummary) -> Bool,
  persist? : async (Json) -> Unit,
  timeout_ms~ : Int32 = 30000,
) -> Unit {
  let mut delay_ms = 1000
  while true {
    flush_sends(c)
    let resp = perform(c.prepare(c.sync_request(timeout_ms~))) catch {
      _ => {
        @async.sleep(delay_ms)
        delay_ms = if delay_ms >= 30000 { 60000 } else { delay_ms * 2 }
        continue
      }
    }
    let summary = c.on_sync_response(resp) catch {
      Matrix(e) if e.is_rate_limited() => {
        let wait = @api.retry_delay_ms(resp).unwrap_or(delay_ms.to_int64())
        @async.sleep(wait.to_int())
        continue
      }
      Http(status~, ..) if status >= 500 => {
        @async.sleep(delay_ms)
        delay_ms = if delay_ms >= 30000 { 60000 } else { delay_ms * 2 }
        continue
      }
      e => raise e
    }
    delay_ms = 1000
    if persist is Some(f) {
      f(c.snapshot())
    }
    if !on_sync(summary) {
      break
    }
  }
}
