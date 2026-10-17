/// How a peer record is keyed in the mode/name caches (#52). A ring or invite
/// can arrive under any of these refs and must find the same record.
enum PeerRefFlattening {
    /// The account id, the iroh endpoint id (a different id on split
    /// identities, #56), and the aliases (which carry the stable account
    /// handle).
    static func refs(id: String, endpointId: String?, aliases: [String]?) -> [String] {
        [id, endpointId].compactMap { $0 } + (aliases ?? [])
    }
}
