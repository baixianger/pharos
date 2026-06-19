import Foundation
import AppKit

enum Links {
    static let repo   = "https://github.com/baixianger/pharos"
    static let issues = repo + "/issues"

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
