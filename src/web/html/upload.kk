// annexwyrm/web/html/upload — upload form.
//
// Single-tenant public review site: every review is public the moment you
// upload it. The only choice on this form is whether to ALSO publish the
// file blob (publish_file, default OFF) — unchecked, the file goes only to
// the encrypted archive and no download link is published; checked, it is
// also copied to the public remote and a download link is minted and
// federated. No JavaScript, no per-item privacy, no manual mirror rows.

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
    "    <label>description / review body (Markdown — **bold**, *italic*, [links](url), lists, # headings): <textarea name=\"content\" rows=\"5\"></textarea></label>",
    "    <p class=\"hint\">the file is always copied to the <strong>encrypted archive</strong>. tick <em>publish file now</em> only if you want the blob itself downloadable: that also copies it to the public remote, mints a shareable download link, and federates it. left unticked the file stays archived — the review is published, the download is not.</p>",
    "    <label><input type=\"checkbox\" name=\"publish_file\" value=\"1\"> publish file now (default: archive only, no public download)</label>",
    "  </fieldset>",
    "  <fieldset>",
    "    <legend>rating &amp; review</legend>",
    "    <label>rating:",
    "      <select name=\"rating\">",
    "        <option value=\"99\" selected>unrated</option>",
    "        <option value=\"3\">loved it</option>",
    "        <option value=\"2\">liked it a lot</option>",
    "        <option value=\"1\">liked it</option>",
    "        <option value=\"0\">neutral</option>",
    "        <option value=\"-1\">disliked it</option>",
    "        <option value=\"-2\">disliked it a lot</option>",
    "        <option value=\"-3\">hated it</option>",
    "      </select>",
    "    </label>",
    "    <label>review of (full item URL): <input type=\"url\" name=\"in_reply_to\" placeholder=\"https://server/items/abc123\"></label>",
    "    <label>tags (space- or comma-separated, # optional): <input type=\"text\" name=\"tags\" placeholder=\"mtg kamigawa game-design\"></label>",
    "  </fieldset>",
    "  <button type=\"submit\">save</button>",
    "</form>"
  ]).join("\n")
  layout("upload — annexwyrm", "", "<a href=\"/upload\">upload</a>", body)
