// annexwyrm/web/html/upload — upload form.
//
// The "N remotes" pattern: we ship three blank rows server-side, plus
// a [+] button. Since there is no JavaScript, the [+] is a button that
// submits the *form so far* with `add_row=1`, the server bounces back
// with one more row pre-populated. Simple, no client logic.

module web/html/upload

import web/html/layout

pub fun render-upload-form() : string
  val body = ([
    "<h1>upload</h1>",
    "<form action=\"/upload\" method=\"post\" enctype=\"multipart/form-data\">",
    "  <fieldset>",
    "    <legend>the file</legend>",
    "    <label>file: <input type=\"file\" name=\"file\" required></label>",
    "    <label>title (optional): <input type=\"text\" name=\"name\" placeholder=\"defaults to filename\"></label>",
    "    <label>content warning / abstract: <textarea name=\"summary\" rows=\"2\"></textarea></label>",
    "    <label>description / review body (HTML, hyperlinks welcome): <textarea name=\"content\" rows=\"5\"></textarea></label>",
    "    <label>privacy:",
    "      <select name=\"privacy\">",
    "        <option value=\"private\" selected>private — never federated</option>",
    "        <option value=\"unlisted\">unlisted — public URL, no follower delivery</option>",
    "        <option value=\"followers\">followers only</option>",
    "        <option value=\"public\">public — followers + Public</option>",
    "      </select>",
    "    </label>",
    "  </fieldset>",
    "  <fieldset>",
    "    <legend>rating &amp; review</legend>",
    "    <p class=\"hint\">rate this on a 7-point scale — <code>-3</code> hated it, <code>0</code> neutral, <code>+3</code> loved it. leave at <em>unrated</em> when you just want to archive without an opinion. fill in <em>review of</em> with the URL of the item you're reviewing.</p>",
    "    <label>rating:",
    "      <select name=\"rating\">",
    "        <option value=\"99\" selected>(unrated)</option>",
    "        <option value=\"3\">+3  ★★★  loved it</option>",
    "        <option value=\"2\">+2  ★★   liked it a lot</option>",
    "        <option value=\"1\">+1  ★    liked it</option>",
    "        <option value=\"0\"> 0       neutral</option>",
    "        <option value=\"-1\">-1  ☆   disliked it</option>",
    "        <option value=\"-2\">-2  ☆☆  disliked it a lot</option>",
    "        <option value=\"-3\">-3  ☆☆☆ hated it</option>",
    "      </select>",
    "    </label>",
    "    <label>review of (full item URL): <input type=\"url\" name=\"in_reply_to\" placeholder=\"https://server/items/abc123\"></label>",
    "  </fieldset>",
    "  <fieldset>",
    "    <legend>mirrors (reserve keys / URLs)</legend>",
    "    <p class=\"hint\">attach as many mirrors as you like — rsync.net path, an https:// URL, a magnet, anything. only those marked <em>published</em> appear in the federated <code>url[]</code>. <strong>rclone</strong> and <strong>git-annex</strong> mirrors receive the bytes automatically on upload; <strong>url</strong> and <strong>ipfs</strong> are just pointers we trust you to keep alive.</p>",
    remote-row(0),
    remote-row(1),
    remote-row(2),
    "  </fieldset>",
    "  <button type=\"submit\">save</button>",
    "</form>"
  ]).join("\n")
  layout("upload — annexwyrm", "", "<a href=\"/upload\">upload</a>", body)

fun remote-row( idx : int ) : string
  ([
    "    <div class=\"remote-row\">",
    "      <select name=\"remote_kind\">",
    "        <option value=\"url\" selected>url</option>",
    "        <option value=\"rclone\">rclone</option>",
    "        <option value=\"git-annex\">git-annex</option>",
    "        <option value=\"ipfs\">ipfs</option>",
    "      </select>",
    "      <input type=\"text\" name=\"remote_target\" placeholder=\"https://… or remote:path\">",
    "      <input type=\"text\" name=\"remote_label\" placeholder=\"label\" size=\"15\">",
    "    </div>"
  ]).join("\n")
