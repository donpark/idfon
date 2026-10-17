// Runnable check for `PeerRefFlattening.refs` (not part of the Xcode target).
// Guards the #52 cache-flattening contract: a peer record is keyed in the
// mode/name caches under every ref it can be addressed by — the account id,
// the iroh endpoint id (a different id on split identities, #56), and the
// aliases (which carry the stable account handle).
//
//   swiftc -o /tmp/ckrefcheck \
//     ios/Idfon/PeerRefFlattening.swift ios/Checks/PeerRefFlatteningCheck/main.swift
//   /tmp/ckrefcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

check(PeerRefFlattening.refs(id: "acct", endpointId: "ep", aliases: ["h1", "h2"]) == ["acct", "ep", "h1", "h2"],
      "every ref of the record is a cache key, in order")
check(PeerRefFlattening.refs(id: "acct", endpointId: nil, aliases: ["h1"]) == ["acct", "h1"],
      "a record without an endpoint id keeps its other refs")
check(PeerRefFlattening.refs(id: "acct", endpointId: "ep", aliases: nil) == ["acct", "ep"],
      "a record without aliases keeps id and endpoint")
check(PeerRefFlattening.refs(id: "acct", endpointId: nil, aliases: nil) == ["acct"],
      "a bare record is keyed by its id")
check(PeerRefFlattening.refs(id: "57877", endpointId: "f124", aliases: ["h"]).contains("f124"),
      "a split identity (#56) is findable under its endpoint id")

print("ALL OK")
