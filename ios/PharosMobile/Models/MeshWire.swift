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
    /// Stable agent identity is the member/session ID. `who` can return one row
    /// per room membership, so keep the newest row for the same ID without
    /// collapsing two different agents that happen to share a nick.
    static func byID(_ members: [MeshMember]) -> [String: MeshMember] {
        members.reduce(into: [:]) { result, member in
            if result[member.id] == nil || member.lastSeen >= result[member.id]!.lastSeen {
                result[member.id] = member
            }
        }
    }

    /// Display aliases are a secondary multi-index, never an identity map.
    static func idsByNick(_ membersByID: [String: MeshMember]) -> [String: Set<String>] {
        membersByID.values.reduce(into: [:]) { result, member in
            result[member.nick.lowercased(), default: []].insert(member.id)
        }
    }

    static func matching(nick: String, in membersByID: [String: MeshMember]) -> [MeshMember] {
        let ids = idsByNick(membersByID)[nick.lowercased()] ?? []
        return ids.compactMap { membersByID[$0] }.sorted { $0.id < $1.id }
    }
}
