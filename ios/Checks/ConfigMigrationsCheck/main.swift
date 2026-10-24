// Runnable check for `ConfigMigrations` (not part of the Xcode target).
// Guards the config-schema migration contract: steps run exactly once (the
// version bump rides with each step), test-rig edge URLs are repointed at the
// production edge, deliberate config is never touched, and a completed
// migration is a no-op on re-run.
//
//   swiftc -o /tmp/cfgmigcheck \
//     ios/Idfon/ConfigMigrations.swift ios/Idfon/IdfonLog.swift \
//     ios/Checks/ConfigMigrationsCheck/main.swift
//   /tmp/cfgmigcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let edge = ConfigMigrations.edgeURLKey
let ticket = ConfigMigrations.edgeTicketKey
let version = ConfigMigrations.versionKey

// Fresh install: no config, just the schema version landing at current.
var w = ConfigMigrations.migrate(storedVersion: 0, config: [:])
check(w.count == 1 && w[0].key == version && w[0].value == "1", "fresh install only records the schema version")

// The incident: a rig edge URL is repointed at production, ticket untouched.
w = ConfigMigrations.migrate(storedVersion: 0, config: [edge: "http://192.168.1.252:8090", ticket: "e2e"])
check(w.contains(where: { $0.key == edge && $0.value == ConfigMigrations.productionEdgeURL }),
      "rig edge url is repointed at production")
check(!w.contains(where: { $0.key == ticket }), "the requester ticket is left alone")
check(w.last?.key == version && w.last?.value == "1", "the version bump lands after the step's writes")

// Deliberate (public) edge config is never touched.
w = ConfigMigrations.migrate(storedVersion: 0, config: [edge: "https://edge.example.com"])
check(!w.contains(where: { $0.key == edge }), "a public edge url is untouched")

// Already-current config: nothing runs (the one-time semantics).
w = ConfigMigrations.migrate(storedVersion: ConfigMigrations.currentVersion,
                             config: [edge: "http://localhost:8090"])
check(w.isEmpty, "a current schema runs nothing")

// Idempotence: apply the writes, re-run, expect silence. Loopback rigs too.
let rig = [edge: "http://127.0.0.1:8090"]
var applied = rig
for write in ConfigMigrations.migrate(storedVersion: 0, config: rig) {
    applied[write.key] = write.value
}
check(applied[edge] == ConfigMigrations.productionEdgeURL, "a localhost rig is repointed too")
check(applied[version].flatMap(Int.init) == ConfigMigrations.currentVersion, "the applied version is current")
w = ConfigMigrations.migrate(storedVersion: applied[version].flatMap(Int.init) ?? -1, config: applied)
check(w.isEmpty, "re-running after apply is a no-op")

// Host classification: private yes, public no.
check(ConfigMigrations.isPrivateHost("10.1.2.3"), "10/8 is private")
check(ConfigMigrations.isPrivateHost("172.16.0.1"), "172.16/12 is private")
check(!ConfigMigrations.isPrivateHost("172.32.0.1"), "172.32 is public")
check(!ConfigMigrations.isPrivateHost("8.8.8.8"), "a public IP is not private")

print("ALL OK")
