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
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9._-]+)"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let nick = String(text[r])
            return seen.insert(nick).inserted ? nick : nil
        }
    }
}

enum RosterIndex {
    /// `who` returns one row per room membership, so an agent joined to several
    /// rooms legitimately appears more than once. Keep its newest presence row
    /// instead of using Dictionary(uniqueKeysWithValues:), which traps.
    static func byNick(_ members: [MeshMember]) -> [String: MeshMember] {
        members.reduce(into: [:]) { result, member in
            if result[member.nick] == nil || member.lastSeen >= result[member.nick]!.lastSeen {
                result[member.nick] = member
            }
        }
    }
}
