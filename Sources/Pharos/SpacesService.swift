import CoreGraphics
import Foundation

/// Private SkyLight/CoreGraphics symbols for reading and switching macOS Spaces.
/// All declarations are `@_silgen_name` wrappers — they bind to symbols present
/// at runtime in the CoreGraphics / SkyLight frameworks linked by AppKit.
/// Every call is wrapped defensively; failure silently degrades to a no-op.

// MARK: - Private symbol declarations

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: UInt64)

// MARK: - SpacesService

enum SpacesService {

    // MARK: Public interface

    /// Number of user spaces on the main display.
    /// Returns 1 if the count cannot be determined (safe lower bound).
    static func spaceCount() -> Int {
        guard let spaces = userSpaceIDs(on: mainDisplay()) else { return 1 }
        return max(spaces.count, 1)
    }

    /// Switch to the given 1-based desktop index on the main display.
    /// Returns `true` if the switch was attempted, `false` if the index is out of
    /// range, the private APIs are unavailable, or any intermediate step fails.
    /// Never crashes or blocks the main thread for more than a trivial moment.
    @discardableResult
    static func switchToDesktop(_ index: Int) -> Bool {
        guard index >= 1 else { return false }
        let cid = CGSMainConnectionID()
        guard let (displayID, spaces) = displayAndSpaces(cid: cid) else { return false }
        guard index <= spaces.count else { return false }
        let targetSpaceID = spaces[index - 1]
        CGSManagedDisplaySetCurrentSpace(cid, displayID as CFString, targetSpaceID)
        // Allow the space switch to settle before the caller launches a window.
        // A brief synchronous sleep here is intentional and negligible (~0.3 s).
        Thread.sleep(forTimeInterval: 0.3)
        return true
    }

    // MARK: Private helpers

    /// Returns `(displayIdentifier, [spaceID])` for the main display, or nil on failure.
    private static func displayAndSpaces(cid: Int32) -> (String, [UInt64])? {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
              let displayDict = arr.first else { return nil }

        // Display identifier string (e.g. "Main" or a UUID-style string).
        let displayID = (displayDict["Display Identifier"] as? String) ?? "Main"

        guard let spaces = userSpaceIDs(from: displayDict) else { return nil }
        return (displayID, spaces)
    }

    /// Returns the display identifier for the primary display.
    private static func mainDisplay() -> String {
        let cid = CGSMainConnectionID()
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
              let displayDict = arr.first,
              let id = displayDict["Display Identifier"] as? String else { return "Main" }
        return id
    }

    /// Returns ordered space IDs from a display dict, nil on any parsing failure.
    private static func userSpaceIDs(from displayDict: [String: Any]) -> [UInt64]? {
        guard let spacesArray = displayDict["Spaces"] as? [[String: Any]] else { return nil }
        var ids: [UInt64] = []
        for spaceDict in spacesArray {
            // Skip non-user spaces (type != 0 are fullscreen/system spaces).
            if let type_ = spaceDict["type"] as? Int, type_ != 0 { continue }
            if let id = spaceDict["ManagedSpaceID"] as? UInt64 {
                ids.append(id)
            } else if let id = spaceDict["id64"] as? UInt64 {
                ids.append(id)
            } else if let id = (spaceDict["ManagedSpaceID"] ?? spaceDict["id64"]) {
                // Fallback: NSNumber → UInt64
                if let n = id as? NSNumber { ids.append(n.uint64Value) }
            }
        }
        return ids.isEmpty ? nil : ids
    }

    /// Convenience: returns space IDs for the given display identifier, or nil.
    private static func userSpaceIDs(on displayID: String) -> [UInt64]? {
        let cid = CGSMainConnectionID()
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return nil }
        for displayDict in arr {
            let did = (displayDict["Display Identifier"] as? String) ?? ""
            if did == displayID || displayID == "Main" {
                if let ids = userSpaceIDs(from: displayDict) { return ids }
            }
        }
        // Fallback: just use the first display dict.
        return arr.first.flatMap { userSpaceIDs(from: $0) }
    }
}
