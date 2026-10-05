import os

/// Native-app logging under one `os.Logger` subsystem (`app.idfon`), so app
/// output is filterable and level-tagged, and can be shipped to the idfon
/// telemetry collector (`log stream --predicate 'subsystem == "app.idfon"'`).
///
/// Category defaults to the source file (`#fileID`), so a predicate can narrow
/// to e.g. `category == "Idfon/Calls.swift"`. Values are logged `.public` to
/// match the visibility the previous `NSLog` calls had.
///
/// Note: the native apps do not export OTLP themselves (the daemon dylib stays
/// lean), so these lines do not carry the trace id; see docs/observability.md.
func idfonLog(_ message: String, file: String = #fileID) {
    logToIdfon(.info, message, file)
}

func idfonError(_ message: String, file: String = #fileID) {
    logToIdfon(.error, message, file)
}

private func logToIdfon(_ level: OSLogType, _ message: String, _ file: String) {
    Logger(subsystem: "app.idfon", category: file).log(level: level, "\(message, privacy: .public)")
}
