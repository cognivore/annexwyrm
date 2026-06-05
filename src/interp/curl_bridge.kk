// annexwyrm/interp/curl_bridge — Fetch & Deliver via libcurl.
//
// One C function services both GET and POST. The handler shapes the
// call site to fit each effect.

module interp/curl_bridge

import effects/fetch
import effects/deliver
import effects/http

extern import
  c file "../../csrc/curl_bridge.c"

// `kk-curl(method, url, headers, body)` returns:
//   "<status>\x1f<header-block>\x1f<body>"
// where header-block is "k:v\nk:v\n…" and status is decimal.
// Network errors return status = 0 and empty body.
extern kk-curl( method : string, url : string, headers : string, body : string ) : <ndet,net> string
  c "kk_aw_curl"

fun encode-headers( hs : list<(string,string)> ) : string
  hs.map(fn(h) h.fst ++ ": " ++ h.snd).join("\n")

fun parse-response( s : string ) : http-response
  match s.split("\x1f")
    Cons(stat, Cons(hdrs, Cons(body, _))) ->
      Http-response(
        stat.parse-int.default(0),
        parse-headers(hdrs),
        body
      )
    _ -> Http-response(0, [], "")

fun parse-headers( hdrs : string ) : list<(string,string)>
  if hdrs == "" then []
  else hdrs.split("\n").flatmap(parse-one-header)

fun parse-one-header( line : string ) : list<(string,string)>
  match line.find(":")
    Nothing -> []
    Just(slc) -> [(slc.before.string.trim.to-lower, slc.after.string.trim)]

pub fun with-curl-fetch( action : () -> <fetch,ndet,net|e> a ) : <ndet,net|e> a
  with handler
    fun http-get(url : string, accept : string)
      parse-response(kk-curl("GET", url, "Accept: " ++ accept, ""))
  action()

pub fun with-curl-deliver( action : () -> <deliver,ndet,net|e> a ) : <ndet,net|e> a
  with handler
    fun http-post(url : string, headers : list<(string,string)>, body : string)
      parse-response(kk-curl("POST", url, encode-headers(headers), body))
  action()
