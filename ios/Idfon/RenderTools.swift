import Foundation

/// The app-owned tool catalog a JSON-render artifact may invoke
/// (`docs/idfon-edge.md`, P5). Only names registered here can run;
/// anything else is `RenderError.unknown`. This is the same shape an MCP tool
/// registry takes — the idfon operations double as the action set.
enum RenderTools {
    /// `defaultPeer` is the conversation the block arrived in, so a spec's
    /// action can target "this contact" without naming it; `dial` is the
    /// chat's call path (a playable contact plays; hang up stops).
    static func make(
        client: IdfonClient = IdfonClient(),
        defaultPeer: String? = nil,
        dial: ((String, String?) -> Void)? = nil
    ) -> RenderToolRegistry {
        let registry = RenderToolRegistry()
        registry.audit = { ActionAudit.shared.record($0) }

        registry.register(RenderTool(
            name: "idfon.status",
            description: "Show daemon readiness and the active identity",
            sensitive: false,
            run: { _ in
                guard let status = try? await client.status() else { return "daemon unavailable" }
                return "ready=\(status.ready) identity=\(status.identityName)"
            }))

        registry.register(RenderTool(
            name: "idfon.peers",
            description: "List contacts",
            sensitive: false,
            run: { _ in
                guard let peers = try? await client.peers() else { return "could not list peers" }
                return peers.isEmpty ? "no contacts" : peers.compactMap(\.name).joined(separator: ", ")
            }))

        registry.register(RenderTool(
            name: "idfon.message.send",
            description: "Send a text message to a peer",
            sensitive: true,
            run: { args in
                guard let peer = args["peer"]?.string ?? defaultPeer, let text = args["text"]?.string else {
                    return "peer and text are required"
                }
                do {
                    try await client.sendText(to: peer, text)
                    return "sent to \(peer)"
                } catch {
                    return "send failed: \(error.localizedDescription)"
                }
            }))

        registry.register(RenderTool(
            name: "idfon.call",
            description: "Start a call to a peer — a playable contact (a radio "
                + "station) starts playing immediately; hanging up stops it",
            sensitive: true,
            run: { args in
                guard let dial else { return "calling is not available here" }
                guard let peer = args["peer"]?.string ?? defaultPeer else { return "peer is required" }
                // A menu item's payload arrives as `value`; `show` names the
                // selection explicitly (docs/live-radio.md "Menu contact").
                let show = args["show"]?.string ?? args["value"]?.string
                dial(peer, show)
                return "calling \(peer)"
            }))

        return registry
    }
}
