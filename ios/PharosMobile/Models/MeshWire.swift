import Foundation
import PharosMeshProtocol

typealias MeshRequest = PharosMeshProtocol.MeshRequest
typealias MeshEvent = PharosMeshProtocol.MeshEvent
typealias MeshMessage = MeshMsg
typealias MeshReply = PharosMeshProtocol.MeshReply
typealias MeshAttachment = PharosMeshProtocol.MeshAttachment
typealias MeshRoom = MeshRoomInfo
typealias MeshMember = MeshMemberInfo
typealias MeshNodeInfo = PharosMeshProtocol.MeshNodeInfo
typealias MeshNodeCommand = PharosMeshProtocol.MeshNodeCommand
typealias MeshPairingCredential = PharosMeshProtocol.MeshPairingCredential
typealias MeshResponse = PharosMeshProtocol.MeshResponse
typealias MeshSessionState = PharosMeshProtocol.MeshSessionState

enum MentionParser {
    static func targets(in text: String) -> [String] {
        let pattern = #"(?:^|\s)@([a-zA-Z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var result: [String] = []
        for m in matches where m.numberOfRanges >= 2 {
            let nick = ns.substring(with: m.range(at: 1))
            if seen.insert(nick).inserted { result.append(nick) }
        }
        return result
    }
}
