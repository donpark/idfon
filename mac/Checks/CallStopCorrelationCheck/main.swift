// Runnable check for `CallStopCorrelation.names` (not part of the app target).
// Guards the #60 stop-correlation contract: a stop naming the current call
// ends it, a stop naming an older call is ignored, and an unticketed (legacy)
// stop keeps the old terminate behavior.
//
//   swiftc -o /tmp/mkstopcheck \
//     mac/Sources/Idfon/CallStopCorrelation.swift mac/Checks/CallStopCorrelationCheck/main.swift
//   /tmp/mkstopcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

check(CallStopCorrelation.names("ticket-a", current: "ticket-a"),
      "stop naming the current call ends it")
check(!CallStopCorrelation.names("ticket-old", current: "ticket-new"),
      "stop naming an older call is ignored")
check(CallStopCorrelation.names("", current: "ticket-new"),
      "unticketed legacy stop still ends the call")
check(CallStopCorrelation.names("", current: nil),
      "unticketed stop with no generation keeps legacy behavior")
check(!CallStopCorrelation.names("ticket-a", current: nil),
      "ticketed stop cannot name a call that has no generation")

print("ALL OK")
