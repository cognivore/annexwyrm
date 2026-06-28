// annexwyrm/web/html/help — static help pages (server-rendered, no JS).
//
// The storage-backend guide, linked from the settings page's [?]. Written for
// someone who has never used rclone. All content is author-controlled static
// HTML; the few `<`/`>`/`&` inside code samples are pre-escaped here.

module web/html/help

import web/html/layout

pub fun render-storage-help( max-width : string = "1080px" ) : string
  val body = ([
    "<h1>setting up your storage backend</h1>",
    "<p class=\"subtitle\">annexwyrm stores your files on <strong>your own cloud</strong> (Google Drive, S3, Dropbox, …) using <a href=\"https://rclone.org\" target=\"_blank\" rel=\"noopener\">rclone</a>. This server never stores your files — you host your own content. Here's how, from scratch.</p>",

    "<h2>where are my secrets?</h2>",
    "<p>Your secrets live <strong>inside the rclone config you paste</strong>:</p>",
    "<ul>",
    "  <li>for Google Drive (and most clouds): an OAuth <strong>token</strong> — it lets the server read and write your cloud.</li>",
    "  <li>if you turn on encryption (recommended): your <strong>password(s)</strong>.</li>",
    "</ul>",
    "<p>The server keeps that config in a <strong>private file (mode 0600)</strong>, readable only by the annexwyrm daemon, and <strong>never shows it to anyone else</strong>. Other members can download your files (the server decrypts them on the fly for a download), but they never see your config or your secrets.</p>",

    "<h2>what you'll end up with</h2>",
    "<p>A short rclone config (a few lines of text) and two named <em>remotes</em>:</p>",
    "<ul>",
    "  <li><strong>archive</strong> — encrypted, private; <em>everything</em> you upload is stored here.</li>",
    "  <li><strong>public</strong> — where a file goes when you choose to <em>publish</em> it for download.</li>",
    "</ul>",

    "<h2>step 1 — install rclone on your computer</h2>",
    "<p>Download it from <a href=\"https://rclone.org/downloads/\" target=\"_blank\" rel=\"noopener\">rclone.org/downloads</a> (or <code>brew install rclone</code> / <code>apt install rclone</code>). You configure it on your own machine, then copy the result here.</p>",

    "<h2>step 2 — connect your cloud (example: Google Drive)</h2>",
    "<p>Run <code>rclone config</code> and answer the prompts:</p>",
    "<ul>",
    "  <li><code>n</code> for a new remote, name it e.g. <code>gdrive</code></li>",
    "  <li>choose <strong>drive</strong> (Google Drive)</li>",
    "  <li>accept the defaults; when a browser opens, log in and click <em>Allow</em>.</li>",
    "</ul>",
    "<p>That creates a <code>[gdrive]</code> remote holding your access token.</p>",

    "<h2>step 3 (recommended) — turn on encryption</h2>",
    "<p>So your files are encrypted on your Drive (only your password can read them):</p>",
    "<ul>",
    "  <li><code>rclone config</code> → <code>n</code> → name it e.g. <code>gdrive-crypt</code></li>",
    "  <li>choose <strong>crypt</strong></li>",
    "  <li>set <code>remote</code> to a folder, e.g. <code>gdrive:annexwyrm</code></li>",
    "  <li>encrypt filenames, then set a password (and salt). <strong>Write it down</strong> — lose it and the files are gone.</li>",
    "</ul>",

    "<h2>step 4 — find your config file</h2>",
    "<p>Run <code>rclone config file</code> to see its path (usually <code>~/.config/rclone/rclone.conf</code>). It looks like:</p>",
    "<pre><code>[gdrive]\ntype = drive\ntoken = {\"access_token\":\"...\",\"refresh_token\":\"...\"}\n\n[gdrive-crypt]\ntype = crypt\nremote = gdrive:annexwyrm\npassword = ...\npassword2 = ...</code></pre>",

    "<h2>step 5 — paste it into settings</h2>",
    "<ul>",
    "  <li>Copy the <strong>whole file</strong> into the <em>rclone.conf</em> box in <a href=\"/settings\">settings</a>.</li>",
    "  <li><strong>archive remote</strong> = your encrypted remote + a folder, e.g. <code>gdrive-crypt:files</code></li>",
    "  <li><strong>public remote</strong> = a plain (un-encrypted) remote + folder for downloads, e.g. <code>gdrive:annexwyrm-public</code></li>",
    "  <li>(optional) <strong>public URL base</strong> — only if you serve downloads through a CDN/public bucket.</li>",
    "  <li>Click <strong>save &amp; test storage</strong>. The server does a real round-trip (writes a tiny test file, reads it back, deletes it) and tells you if your secrets work — <em>before</em> you ever upload.</li>",
    "</ul>",

    "<h2>good to know</h2>",
    "<ul>",
    "  <li>Only <strong>cloud</strong> backends are accepted (drive, s3, b2, sftp, …) — never a local path. Your files must live on your own cloud, not on this server.</li>",
    "  <li>rclone keeps your access token fresh automatically (it stores a long-lived <em>refresh</em> token), and the server preserves those refreshes — so you set this up <strong>once and forget it</strong>. You only need to re-paste if you revoke this app's access to your cloud, or switch clouds.</li>",
    "  <li>This server only <em>relays</em> a download when someone views a file — it never keeps a copy.</li>",
    "</ul>",
    "<p><a href=\"/settings\">← back to settings</a></p>"
  ]).join("\n")
  layout("storage setup — annexwyrm", "",
    "<a href=\"/\">archive</a> · <a href=\"/settings\">settings</a> · storage help",
    body, max-width)
