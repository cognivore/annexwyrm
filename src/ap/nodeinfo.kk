// annexwyrm/ap/nodeinfo — `/.well-known/nodeinfo` + NodeInfo 2.1.
//
// Pure helpers: stats and the link discovery doc. The values for
// `total-users` etc. are supplied by the caller (which talks to the DB).

module ap/nodeinfo

import core/json

pub val annexwyrm-version : string = "0.1.0"

// The discovery document at `/.well-known/nodeinfo`.
pub fun discovery-doc( base-url : string ) : json
  obj([
    ("links", arr([
      obj([
        ("rel",  string/json("http://nodeinfo.diaspora.software/ns/schema/2.1")),
        ("href", string/json(base-url ++ "/nodeinfo/2.1"))
      ])
    ]))
  ])

// The NodeInfo 2.1 document.
pub fun nodeinfo-doc(
    total-users      : int,
    active-month     : int,
    active-half-year : int,
    local-items      : int,
    open-registrations : bool
  ) : json
  obj([
    ("version", string/json("2.1")),
    ("software", obj([
      ("name",       string/json("annexwyrm")),
      ("version",    string/json(annexwyrm-version)),
      ("repository", string/json("https://github.com/cognivore/annexwyrm"))
    ])),
    ("protocols", arr([string/json("activitypub")])),
    ("services", obj([
      ("inbound",  arr([])),
      ("outbound", arr([]))
    ])),
    ("openRegistrations", bool/json(open-registrations)),
    ("usage", obj([
      ("users", obj([
        ("total",         int/json(total-users)),
        ("activeMonth",   int/json(active-month)),
        ("activeHalfyear", int/json(active-half-year))
      ])),
      ("localPosts", int/json(local-items))
    ])),
    ("metadata", obj([
      ("nodeName", string/json("annexwyrm")),
      ("features", arr([
        string/json("multi-remote-storage"),
        string/json("rclone"),
        string/json("git-annex")
      ]))
    ]))
  ])
