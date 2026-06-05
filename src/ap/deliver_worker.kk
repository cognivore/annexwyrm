// annexwyrm/ap/deliver_worker — drain the `delivery` queue.
//
// The pure-algorithm part of "send the next batch of activities". The
// loop itself lives in the interpreter / main wherever `serve` is.

module ap/deliver_worker

import core/types
import core/json
import effects/db
import effects/time
import effects/log
import effects/config
import effects/crypto
import effects/deliver
import effects/http
import ap/sign

// Drain up to `batch-size` ready deliveries, attempt each, update its
// row. Returns the number of rows actually processed.
pub fun drain-deliveries( batch-size : int )
  : <db,time,log,config,crypto,deliver|e> int
  val now = now-iso()
  val rows = query(
    "SELECT id, activity_id, sender_id, inbox_url, attempts " ++
    "FROM delivery WHERE state = ? AND next_attempt <= ? " ++
    "ORDER BY id LIMIT ?",
    [txt("pending"), txt(now), num(batch-size)]
  )
  rows.foreach(deliver-one)
  rows.length

fun deliver-one( row : sql-row )
  : <db,time,log,config,crypto,deliver|e> ()
  val delivery-id = match row.col(0) { SqlInt(n) -> n; _ -> 0 }
  val activity-id = match row.col(1) { SqlText(s) -> s; _ -> "" }
  val sender-id   = match row.col(2) { SqlText(s) -> s; _ -> "" }
  val inbox-url   = match row.col(3) { SqlText(s) -> s; _ -> "" }
  val attempts    = match row.col(4) { SqlInt(n) -> n; _ -> 0 }

  // Look up the activity body and the sender's private key.
  val body = query("SELECT raw FROM activity WHERE id = ?",
                   [txt(activity-id)]).first-text.default("")
  val priv = query("SELECT private_key_pem FROM actor WHERE id = ?",
                   [txt(sender-id)]).first-text.default("")

  if body == "" || priv == "" then
    mark-failed(delivery-id, "missing activity or private key")
  else
    val date = now-http()
    val key-id = sender-id ++ "#main-key"
    val (sig-hdr, digest-hdr, _) =
      sign-outbound("post", inbox-url, body, date, priv, key-id)
    val headers = [
      ("Date",         date),
      ("Digest",       digest-hdr),
      ("Signature",    sig-hdr),
      ("Content-Type", "application/activity+json"),
      ("Accept",       "application/activity+json")
    ]
    val resp = http-post(inbox-url, headers, body)
    if resp.ok then mark-success(delivery-id)
    else mark-retry(delivery-id, attempts + 1,
                    "HTTP " ++ resp.status.show)

fun mark-success( delivery-id : int ) : db ()
  val _ = exec("UPDATE delivery SET state = ? WHERE id = ?",
               [txt("success"), num(delivery-id)])
  ()

fun mark-failed( delivery-id : int, reason : string ) : db ()
  val _ = exec("UPDATE delivery SET state = ?, last_error = ? WHERE id = ?",
               [txt("failed"), txt(reason), num(delivery-id)])
  ()

// Schedule a retry with exponential backoff. After 8 attempts (~17h),
// give up.
fun mark-retry( delivery-id : int, attempts : int, reason : string )
  : <db,time|e> ()
  if attempts >= 8 then
    val _ = exec(
      "UPDATE delivery SET state = ?, attempts = ?, last_error = ? WHERE id = ?",
      [txt("failed"), num(attempts), txt(reason), num(delivery-id)])
    ()
  else
    val delay-seconds = backoff(attempts)
    val next = now-unix() + delay-seconds
    val _ = exec(
      "UPDATE delivery SET state = ?, attempts = ?, next_attempt = ?, last_error = ? " ++
      "WHERE id = ?",
      [txt("pending"), num(attempts),
       txt(iso-from-unix(next)),
       txt(reason), num(delivery-id)])
    ()

// Exponential backoff in seconds: 30, 60, 120, 300, 600, 1800, 3600, 7200.
fun backoff( attempts : int ) : int
  if attempts <= 1 then 30
  elif attempts == 2 then 60
  elif attempts == 3 then 120
  elif attempts == 4 then 300
  elif attempts == 5 then 600
  elif attempts == 6 then 1800
  elif attempts == 7 then 3600
  else 7200

