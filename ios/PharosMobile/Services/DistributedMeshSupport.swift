import PharosMeshProtocol

/// The iOS target imports the same transport contracts as macOS and the Mesh
/// CLI. Iroh integration will enter behind this boundary instead of growing a
/// second mobile-only wire protocol.
enum DistributedMeshSupport {
    static let protocolVersion = DistributedMeshProtocol.version
    static let alpn = DistributedMeshProtocol.alpn
}
