import SwiftUI

/// Top-level navigation, grouped by function the way CleanMyMac organises its
/// sidebar (Cleanup / Hardware / Applications). The sidebar stays quiet:
/// narrow, same surface family as the content, small rows.
struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home"
        case dashboard = "Dashboard"
        case systemJunk = "System Junk"
        case xcodeJunk = "Xcode Junk"
        case largeFiles = "Large Files"
        case duplicates = "Duplicates"
        case spaceLens = "Space Lens"
        case permissions = "Permissions"
        case maintenance = "Maintenance"
        case startupItems = "Startup Items"
        case processes = "Processes"
        case fans = "Fans"
        case sensors = "Sensors"
        case uninstaller = "Uninstaller"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .systemJunk: return "sparkles"
            case .xcodeJunk: return "hammer"
            case .largeFiles: return "doc.text.magnifyingglass"
            case .duplicates: return "doc.on.doc"
            case .spaceLens: return "square.grid.3x3.topleft.filled"
            case .permissions: return "hand.raised"
            case .maintenance: return "wrench.and.screwdriver"
            case .startupItems: return "power"
            case .processes: return "cpu"
            case .fans: return "fan"
            case .sensors: return "thermometer.variable"
            case .uninstaller: return "trash"
            }
        }
    }

    /// Sidebar layout: (group header, items). A nil header renders ungrouped.
    private static let groups: [(header: String?, items: [Section])] = [
        (nil, [.home, .dashboard]),
        ("Cleanup", [.systemJunk, .xcodeJunk, .largeFiles, .duplicates, .spaceLens]),
        ("Protection", [.permissions]),
        ("Speed", [.maintenance, .startupItems, .processes]),
        ("Hardware", [.fans, .sensors]),
        ("Applications", [.uninstaller]),
    ]

    @EnvironmentObject private var nav: Navigation

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarList
                Divider().opacity(0.5)
                settingsRow
            }
            .background(VisualEffectBackground(material: .sidebar))
        } detail: {
            detail
        }
        .tint(Theme.accent)
        // Scrollbars stay out of the way everywhere; this propagates through
        // the environment to every scroll view and list below.
        .scrollIndicators(.hidden)
    }

    private var sidebarList: some View {
        List(selection: $nav.section) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                    if let header = group.header {
                        SwiftUI.Section {
                            ForEach(group.items) { item in sidebarRow(item) }
                        } header: {
                            Text(header)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        SwiftUI.Section {
                            ForEach(group.items) { item in sidebarRow(item) }
                        }
                    }
                }
            }
        .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 210)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Pinned to the bottom of the sidebar so Settings is reachable from the
    /// main window, not only from the app menu.
    private var settingsRow: some View {
        SettingsLink {
            HStack(spacing: 9) {
                Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 16)
                Text("Settings").font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            NSApplication.shared.activate(ignoringOtherApps: true)
        })
    }

    private var detail: some View {
            // ZStack lets the outgoing and incoming screens overlap during the
            // crossfade; the incoming one rises slightly as it fades in.
            ZStack {
                Group {
                    switch nav.section {
                case .home: HomeView()
                case .dashboard: DashboardView()
                case .systemJunk:
                    CleanerView(nav: nav)
                case .xcodeJunk:
                    CleanerView(title: "Xcode Junk",
                                subtitle: "DerivedData, device support, simulators, archives and tool caches",
                                categories: CleaningEngine.developerJunkCategories,
                                nav: nav)
                case .largeFiles: LargeFilesView()
                case .duplicates: DuplicatesView()
                case .spaceLens: SpaceLensView()
                case .permissions: PermissionsView()
                case .maintenance: MaintenanceView()
                case .startupItems: StartupItemsView()
                case .processes: ProcessesView()
                case .fans: FanView()
                case .sensors: SensorsView()
                case .uninstaller: UninstallerView()
                }
                }
                .id(nav.section)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 14)),
                    removal: .opacity))
            }
            .animation(.easeOut(duration: 0.28), value: nav.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opaque on purpose. A translucent content pane forces AppKit to
            // recomposite the behind-window blur on every scroll frame, which
            // stutters long file lists; vibrancy stays on the sidebar, the way
            // Finder and Mail do it.
            .background(Theme.surface)
    }

    private func sidebarRow(_ section: Section) -> some View {
        Label {
            Text(section.rawValue).font(.system(size: 13))
        } icon: {
            Image(systemName: section.systemImage)
                .font(.system(size: 13))
        }
        .frame(height: 26)
        .tag(section)
    }
}
