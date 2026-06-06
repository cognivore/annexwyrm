// annexwyrm/interp/socket_serve — main HTTP/1.1 loop on a Unix socket.
//
// The C bridge does the byte-level work; here we parse the encoded
// request, dispatch, format the response, and write it back.

module interp/socket_serve

import core/types
import effects/log
import web/server
import interp/str

extern import
  c file "../../csrc/socket_server.c"

pub extern kk-aw-listen( path : string ) : <ndet,net> int
  c "kk_aw_listen"

extern kk-aw-accept( fd : int ) : <ndet,net> int
  c "kk_aw_accept"

// Bounded accept: poll the listen fd for at most `timeout-ms`.
//   >= 0  accepted connection fd
//   -2    timeout (no connection; caller should tick + retry)
//   -1    unrecoverable error
extern kk-aw-accept-timeout( fd : int, timeout-ms : int ) : <ndet,net> int
  c "kk_aw_accept_timeout"

extern kk-aw-read-request( conn : int ) : <ndet,net> string
  c "kk_aw_read_request"

extern kk-aw-write-response( conn : int, encoded : string ) : <ndet,net> int
  c "kk_aw_write_response"

extern kk-aw-close( fd : int ) : <ndet,net> ()
  c "kk_aw_close"

// ----------------------------------------------------------------------
//  Request parsing  (encoded record produced by socket_server.c)
// ----------------------------------------------------------------------

// The C bridge emits: METHOD \x1F PATH \x1F QUERY \x1F REMOTE \x1F HEADERS \x1F BODY
//
// The BODY is the FINAL field because it is binary: any real PDF/JPEG/
// audio contains 0x1F bytes, so a plain split("\x1f") silently truncated
// the body at its first 0x1F — which is exactly how the first real phone
// upload broke ("expected multipart/form-data" on a perfectly good form).
// split-limit peels the five separator-free fields and keeps the
// remainder byte-exact.
pub fun parse-incoming( encoded : string ) : maybe<request>
  match encoded.split-limit("\x1f", 5)
    Just((Cons(method, Cons(path, Cons(query, Cons(remote, Cons(hdrs, Nil))))), body)) ->
      Just(Request(method, path, query, parse-headers(hdrs), body, remote))
    _ -> Nothing

// Split a header block (`name: value\nname: value\n…`) into pairs. Names
// are lowercased.
fun parse-headers( hdrs : string ) : list<(string,string)>
  if hdrs == "" then []
  else hdrs.split("\n").flatmap(fn(line)
    val ln = line.list.drop-trailing-cr.string
    match ln.find(":")
      Nothing -> []
      Just(slc) ->
        val k = slc.before.string.trim.to-lower
        val v = slc.after.string.trim
        [(k, v)]
  )

fun drop-trailing-cr( cs : list<char> ) : list<char>
  match cs.reverse
    Cons('\r', rest) -> rest.reverse
    _ -> cs

// ----------------------------------------------------------------------
//  Response formatting
// ----------------------------------------------------------------------

// Render the response into HTTP/1.1 bytes. We always set Content-Length
// from the *byte* length of the body (not codepoint).
pub fun format-response( r : response ) : string
  val cl = byte-count(r.body).show
  val status-line = "HTTP/1.1 " ++ r.status.show ++ " " ++ r.status-text ++ "\r\n"
  val hdrs = r.headers.map(fn(h) h.fst ++ ": " ++ h.snd).join("\r\n")
  val tail = "Content-Length: " ++ cl ++ "\r\n" ++
             "Connection: close\r\n" ++
             "Server: annexwyrm\r\n"
  status-line ++ (if hdrs == "" then "" else hdrs ++ "\r\n") ++ tail ++ "\r\n" ++ r.body

// ----------------------------------------------------------------------
//  The serve loop
// ----------------------------------------------------------------------

// Run the accept/dispatch/respond loop forever (or until accept errors).
//
// `dispatch` is the caller-provided routing function. `tick` is a caller
// -provided periodic action run on every IDLE timeout only (never on the
// request path — see serve-go) — socket_serve stays decoupled from *what*
// the tick does (e.g. draining deliveries). `timeout-ms` bounds each
// accept so the tick fires on an idle instance instead of starving behind
// a blocking accept(). Effect rows are polymorphic and propagate.
pub fun serve-loop( socket-fd : int,
                    dispatch : (request) -> <ndet,net,div|e> response,
                    tick : () -> <ndet,net,div|e> (),
                    timeout-ms : int )
  : <ndet,net,div|e> ()
  serve-go(socket-fd, dispatch, tick, timeout-ms)

fun serve-go( fd : int,
              dispatch : (request) -> <ndet,net,div|e> response,
              tick : () -> <ndet,net,div|e> (),
              timeout-ms : int )
  : <ndet,net,div|e> ()
  val conn = kk-aw-accept-timeout(fd, timeout-ms)
  if conn == -2 then
    // idle timeout: run the periodic tick, then keep listening.
    tick()
    serve-go(fd, dispatch, tick, timeout-ms)
  elif conn < 0 then
    // -1 (or any other negative): unrecoverable accept error; stop.
    ()
  else
    val encoded = kk-aw-read-request(conn)
    val resp = dispatch-or-bad(encoded, dispatch)
    val _ = kk-aw-write-response(conn, format-response(resp))
    kk-aw-close(conn)
    // NB: the tick runs ONLY on the idle branch above, never here. The
    // tick does blocking delivery I/O (curl POSTs) on this single accept
    // thread; running it after every request would let a hung peer freeze
    // request serving for the whole batch's worth of timeouts. Draining
    // only when idle bounds that to genuinely-idle periods, and the
    // separate `annexwyrm drain` agent is the reliable bulk path.
    serve-go(fd, dispatch, tick, timeout-ms)

fun dispatch-or-bad( encoded : string,
                     dispatch : (request) -> <ndet,net,div|e> response )
  : <ndet,net,div|e> response
  match parse-incoming(encoded)
    Nothing   -> bad-request("malformed request")
    Just(req) -> dispatch(req)
