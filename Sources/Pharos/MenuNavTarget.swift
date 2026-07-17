import Foundation

/// The four workspace surfaces the menu-bar launches, mirroring the iOS tabs
/// (projects · issues · agents · chat). On the Mac these all live in the main
/// window: Projects and the cross-project Issues/Agents overviews are the
/// Dashboard (optionally focused on a section), and Chat opens the rooms view.
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
        case .agents:    .agents
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
