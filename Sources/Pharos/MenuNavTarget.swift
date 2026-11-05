import Foundation

/// The four workspace surfaces the menu-bar launches, mirroring the iOS tabs
/// (projects · issues · agents · chat). Agents opens the dedicated unified
/// session surface; Projects/Issues use the Dashboard and Chat opens rooms.
enum MenuNavTarget: Equatable {
    case projects
    case issues
    case agents
    case chatRooms

    /// When non-nil, the Dashboard scrolls to and highlights this section.
    var dashboardFocus: DashboardFocus? {
        switch self {
        case .projects:  nil
        case .issues:    .issues
        case .agents:    nil
        case .chatRooms: nil
        }
    }
}

/// A Dashboard section a menu-bar nav can jump to. Its raw value is the
/// ScrollViewReader anchor id for that section.
enum DashboardFocus: String, Equatable {
    case issues = "dashboard.section.issues"
    case agents = "dashboard.section.agents"
}
