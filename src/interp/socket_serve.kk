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

extern kk-aw-read-request( conn : int ) : <ndet,net> string
  c "kk_aw_read_request"

extern kk-aw-write-response( conn : int, encoded : string ) : <ndet,net> int
  c "kk_aw_write_response"

extern kk-aw-close( fd : int ) : <ndet,net> ()
  c "kk_aw_close"

// ----------------------------------------------------------------------
//  Request parsing  (encoded record produced by socket_server.c)
// ----------------------------------------------------------------------

// The C bridge emits: METHOD \x1F PATH \x1F QUERY \x1F HEADERS \x1F BODY \x1F REMOTE
pub fun parse-incoming( encoded : string ) : maybe<request>
  match encoded.split("\x1f")
    Cons(method, Cons(path, Cons(query, Cons(hdrs, Cons(body, Cons(remote, _)))))) ->
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

// Run the accept/dispatch/respond loop forever (or until accept fails).
// `dispatch` is the caller-provided routing function. Its effect row is
// polymorphic — it just propagates into the loop's row.
pub fun serve-loop( socket-fd : int,
                    dispatch : (request) -> <ndet,net,div|e> response )
  : <ndet,net,div|e> ()
  serve-go(socket-fd, dispatch)

fun serve-go( fd : int,
              dispatch : (request) -> <ndet,net,div|e> response )
  : <ndet,net,div|e> ()
  val conn = kk-aw-accept(fd)
  if conn < 0 then ()
  else
    val encoded = kk-aw-read-request(conn)
    val resp = dispatch-or-bad(encoded, dispatch)
    val _ = kk-aw-write-response(conn, format-response(resp))
    kk-aw-close(conn)
    serve-go(fd, dispatch)

fun dispatch-or-bad( encoded : string,
                     dispatch : (request) -> <ndet,net,div|e> response )
  : <ndet,net,div|e> response
  match parse-incoming(encoded)
    Nothing   -> bad-request("malformed request")
    Just(req) -> dispatch(req)
