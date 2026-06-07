// annexwyrm/core/markdown — a small, SAFE Markdown → HTML renderer.
//
// Review bodies are authored in Markdown. This converts to HTML for both the
// item page and the federated AP `content`. Safety is the priority: the input
// is HTML-escaped everywhere, only a fixed allow-list of tags is emitted, and
// links are scheme-restricted (http/https/mailto/relative). NO raw HTML from
// the input ever reaches the output — so this is strictly safer than the old
// "content is raw HTML" model.
//
// Supported subset:
//   blocks : paragraphs, `#`..`######` headings, `-`/`*` and `1.` lists,
//            `>` blockquotes, ``` fenced code, `---` horizontal rules
//   inline : **bold**, *italic* / _italic_, `code`, [text](url), \escape
//   single newlines inside a paragraph become <br>.

module core/markdown

// ----------------------------------------------------------------------
//  Entry point
// ----------------------------------------------------------------------

pub fun md-to-html( s : string ) : div string
  val norm = s.replace-all("\r\n", "\n").replace-all("\r", "\n")
  blocks(norm.split("\n")).join("\n")

// ----------------------------------------------------------------------
//  HTML escaping (no raw HTML survives)
// ----------------------------------------------------------------------

fun esc1( c : char ) : string
  if c == '&' then "&amp;"
  elif c == '<' then "&lt;"
  elif c == '>' then "&gt;"
  elif c == '"' then "&quot;"
  else c.string

fun esc-str( s : string ) : string
  s.list.map(esc1).join("")

// HTML-escape a plain string for safe inclusion in HTML text / attributes.
// Exposed so callers folding plain text (titles, URLs) into HTML content do
// the same escaping as the renderer.
pub fun md-escape( s : string ) : string
  esc-str(s)

// ----------------------------------------------------------------------
//  Block parsing
// ----------------------------------------------------------------------

fun blocks( lines : list<string> ) : div list<string>
  match lines
    Nil -> []
    Cons(line, rest) ->
      val t = line.trim
      if t == "" then blocks(rest)
      elif t.starts-with("```").bool then
        val (code, after) = take-fence(rest, [])
        Cons("<pre><code>" ++ code.map(esc-str).join("\n") ++ "</code></pre>", blocks(after))
      elif is-hr(t) then
        Cons("<hr>", blocks(rest))
      elif heading-level(t) > 0 then
        val n = heading-level(t)
        val txt = t.list.drop(n + 1).string   // drop the #s and the space
        Cons("<h" ++ n.show ++ ">" ++ inline(txt) ++ "</h" ++ n.show ++ ">", blocks(rest))
      elif bq-prefix(t) then
        val (q, after) = take-bq(lines, [])
        Cons("<blockquote>" ++ blocks(q).join("\n") ++ "</blockquote>", blocks(after))
      elif ul-rest(t).is-just then
        val (items, after) = take-list(lines, True, [])
        Cons("<ul>" ++ items.map(fn(x) "<li>" ++ inline(x) ++ "</li>").join("") ++ "</ul>", blocks(after))
      elif ol-rest(t).is-just then
        val (items, after) = take-list(lines, False, [])
        Cons("<ol>" ++ items.map(fn(x) "<li>" ++ inline(x) ++ "</li>").join("") ++ "</ol>", blocks(after))
      else
        val (para, after) = take-para(lines, [])
        Cons("<p>" ++ para.map(inline).join("<br>\n") ++ "</p>", blocks(after))

// A fenced code block: consume lines until the closing ```.
fun take-fence( lines : list<string>, acc : list<string> ) : (list<string>, list<string>)
  match lines
    Nil -> (acc.reverse, [])
    Cons(l, rest) -> if l.trim.starts-with("```").bool
      then (acc.reverse, rest)
      else take-fence(rest, Cons(l, acc))

// Consecutive `>`-prefixed lines, with the marker stripped.
fun take-bq( lines : list<string>, acc : list<string> ) : div (list<string>, list<string>)
  match lines
    Nil -> (acc.reverse, [])
    Cons(l, rest) ->
      val t = l.trim
      if bq-prefix(t) then take-bq(rest, Cons(bq-strip(t), acc))
      else (acc.reverse, lines)

// Consecutive list items (ul if `unordered`, else ol), markers stripped.
fun take-list( lines : list<string>, unordered : bool, acc : list<string> ) : div (list<string>, list<string>)
  match lines
    Nil -> (acc.reverse, [])
    Cons(l, rest) ->
      val t = l.trim
      match (if unordered then ul-rest(t) else ol-rest(t))
        Just(item) -> take-list(rest, unordered, Cons(item, acc))
        Nothing    -> (acc.reverse, lines)

// A paragraph: consecutive non-blank lines that don't start a new block.
fun take-para( lines : list<string>, acc : list<string> ) : div (list<string>, list<string>)
  match lines
    Nil -> (acc.reverse, [])
    Cons(l, rest) ->
      val t = l.trim
      if t == "" || is-block-start(t) then (acc.reverse, lines)
      else take-para(rest, Cons(l, acc))

fun is-block-start( t : string ) : div bool
  t.starts-with("```").bool || is-hr(t) || heading-level(t) > 0 ||
  bq-prefix(t) || ul-rest(t).is-just || ol-rest(t).is-just

// ----------------------------------------------------------------------
//  Block detectors
// ----------------------------------------------------------------------

// Number of leading '#' (1..6) iff followed by a space; else 0.
fun heading-level( t : string ) : int
  val hashes = t.list.take-while(fn(c) c == '#').length
  if hashes >= 1 && hashes <= 6 && t.list.drop(hashes).is-cons && t.list.drop(hashes).head.default(' ') == ' '
    then hashes else 0

fun is-hr( t : string ) : bool
  (t == "---" || t == "***" || t == "___") ||
  (t.count >= 3 && t.list.all(fn(c) c == '-'))

fun bq-prefix( t : string ) : bool
  t == ">" || t.starts-with("> ").bool

fun bq-strip( t : string ) : string
  match t.starts-with("> ")
    Just(slc) -> slc.string
    Nothing   -> ""

fun ul-rest( t : string ) : maybe<string>
  match t.starts-with("- ")
    Just(slc) -> Just(slc.string)
    Nothing   -> match t.starts-with("* ")
      Just(slc) -> Just(slc.string)
      Nothing   -> Nothing

// "12. rest" → Just("rest"); else Nothing.
fun ol-rest( t : string ) : maybe<string>
  val digits = t.list.take-while(fn(c) c >= '0' && c <= '9')
  val after = t.list.drop(digits.length).string
  if digits.is-cons && after.starts-with(". ").bool
    then Just(after.list.drop(2).string)
    else Nothing

// ----------------------------------------------------------------------
//  Inline parsing (a left-to-right scan; everything escaped or wrapped)
// ----------------------------------------------------------------------

fun inline( s : string ) : div string
  ig(s.list, [])

fun ig( cs : list<char>, acc : list<string> ) : div string
  match cs
    Nil -> acc.reverse.join("")
    Cons('\\', Cons(c, rest)) -> ig(rest, Cons(esc1(c), acc))
    Cons('`', rest) ->
      match split-at(rest, '`')
        Just((code, after)) -> ig(after, Cons("<code>" ++ esc-str(code) ++ "</code>", acc))
        Nothing             -> ig(rest, Cons("`", acc))
    Cons('*', Cons('*', Cons('*', rest))) ->
      match split-at3(rest, '*', '*', '*')
        Just((inner, after)) -> ig(after, Cons("<strong><em>" ++ inline(inner) ++ "</em></strong>", acc))
        Nothing              -> ig(rest, Cons("***", acc))
    Cons('*', Cons('*', rest)) ->
      match split-at2(rest, '*', '*')
        Just((inner, after)) -> ig(after, Cons("<strong>" ++ inline(inner) ++ "</strong>", acc))
        Nothing              -> ig(rest, Cons("**", acc))
    Cons('*', rest) ->
      match split-at(rest, '*')
        Just((inner, after)) -> ig(after, Cons("<em>" ++ inline(inner) ++ "</em>", acc))
        Nothing              -> ig(rest, Cons("*", acc))
    Cons('_', rest) ->
      match split-at(rest, '_')
        Just((inner, after)) -> ig(after, Cons("<em>" ++ inline(inner) ++ "</em>", acc))
        Nothing              -> ig(rest, Cons("_", acc))
    Cons('[', rest) ->
      match parse-link(rest)
        Just((text, lurl, after)) -> ig(after, Cons(render-link(lurl, text), acc))
        Nothing                   -> ig(rest, Cons("[", acc))
    Cons(c, rest) -> ig(rest, Cons(esc1(c), acc))

// before (as string) up to the first `d`; the remainder after it. Nothing if
// `d` never appears.
fun split-at( cs : list<char>, d : char ) : maybe<(string, list<char>)>
  sa(cs, d, [])

fun sa( cs : list<char>, d : char, acc : list<char> ) : maybe<(string, list<char>)>
  match cs
    Nil -> Nothing
    Cons(c, rest) -> if c == d then Just((acc.reverse.string, rest)) else sa(rest, d, Cons(c, acc))

// before up to the first `a``b` pair; the remainder after it.
fun split-at2( cs : list<char>, a : char, b : char ) : maybe<(string, list<char>)>
  sa2(cs, a, b, [])

fun sa2( cs : list<char>, a : char, b : char, acc : list<char> ) : maybe<(string, list<char>)>
  match cs
    Nil -> Nothing
    Cons(x, rest) ->
      if x == a && rest.head.default(' ') == b
        then Just((acc.reverse.string, rest.drop(1)))
        else sa2(rest, a, b, Cons(x, acc))

fun split-at3( cs : list<char>, a : char, b : char, c : char ) : maybe<(string, list<char>)>
  sa3(cs, a, b, c, [])

fun sa3( cs : list<char>, a : char, b : char, c : char, acc : list<char> ) : maybe<(string, list<char>)>
  match cs
    Nil -> Nothing
    Cons(x, rest) ->
      if x == a && rest.head.default(' ') == b && rest.drop(1).head.default(' ') == c
        then Just((acc.reverse.string, rest.drop(2)))
        else sa3(rest, a, b, c, Cons(x, acc))

// After a '[': parse `text](url)`. Returns (text, url, remainder).
fun parse-link( cs : list<char> ) : maybe<(string, string, list<char>)>
  match split-at(cs, ']')
    Nothing -> Nothing
    Just((text, after)) ->
      match after
        Cons('(', rest) ->
          match split-at(rest, ')')
            Just((u, after2)) -> Just((text, u, after2))
            Nothing           -> Nothing
        _ -> Nothing

fun render-link( lurl : string, text : string ) : div string
  if safe-url(lurl)
    then "<a href=\"" ++ esc-str(lurl) ++ "\" rel=\"nofollow\">" ++ inline(text) ++ "</a>"
    else esc-str("[" ++ text ++ "](" ++ lurl ++ ")")

// Only well-known safe schemes (and genuinely site-relative links). Blocks
// javascript:, data:, vbscript:, etc. Exposed (`pub`) so other render sites
// (the review-of href in item.kk / publish.kk) reuse the SAME guard instead
// of only HTML-escaping — escaping a `javascript:` URL still yields a live
// XSS anchor.
pub fun safe-url( u : string ) : bool
  val l = u.trim.to-lower
  l.starts-with("https://").bool || l.starts-with("http://").bool ||
  l.starts-with("mailto:").bool || site-relative(u)

// A path-relative link: starts with a single '/' (or '#'), NOT '//' or '/\'.
// `//host` / `/\host` are PROTOCOL-relative — the browser navigates off-site —
// so they must NOT pass as "site-relative".
fun site-relative( u : string ) : bool
  u.starts-with("#").bool ||
  (u.starts-with("/").bool && !u.starts-with("//").bool && !u.starts-with("/\\").bool)
