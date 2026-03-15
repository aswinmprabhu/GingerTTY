import AppKit
import SwiftUI
import Combine

private struct TerminalTabBarItem: Identifiable {
    private let controllerRef: Weak<TerminalController>
    private let identifier: ObjectIdentifier

    let title: String
    let subtitle: String?
    let tabColor: TerminalTabColor
    let isSelected: Bool

    init(
        controller: TerminalController,
        title: String,
        subtitle: String?,
        tabColor: TerminalTabColor,
        isSelected: Bool
    ) {
        self.controllerRef = Weak(controller)
        self.identifier = ObjectIdentifier(controller)
        self.title = title
        self.subtitle = subtitle
        self.tabColor = tabColor
        self.isSelected = isSelected
    }

    var id: ObjectIdentifier { identifier }
    var controller: TerminalController? { controllerRef.value }
}

@MainActor
final class TabGroupDataSource: ObservableObject {
    @Published fileprivate var items: [TerminalTabBarItem] = []

    private weak var controller: TerminalController?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: TerminalController) {
        self.controller = controller
        observe(controller: controller)
        refresh()
    }

    static func controllers(from windows: [NSWindow]) -> [TerminalController] {
        windows.compactMap { $0.windowController as? TerminalController }
    }

    private func observe(controller: TerminalController) {
        controller.$tabGroupVersion
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: center.publisher(for: NSWindow.willCloseNotification))
            .merge(with: center.publisher(for: .gingerTTYTabGroupDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if self.shouldRefresh(for: notification.object as? NSWindow) {
                    self.refresh()
                }
            }
            .store(in: &cancellables)
    }

    private func shouldRefresh(for changedWindow: NSWindow?) -> Bool {
        guard let controller, let currentWindow = controller.window else { return false }
        guard let changedWindow else { return true }
        if changedWindow === currentWindow { return true }
        return currentWindow.tabbedWindows?.contains(where: { $0 === changedWindow }) == true
    }

    func refresh() {
        guard let controller, let currentWindow = controller.window else {
            items = []
            return
        }

        let windows = currentWindow.tabGroup?.windows ?? [currentWindow]
        items = Self.controllers(from: windows).map { tabController in
            TerminalTabBarItem(
                controller: tabController,
                title: Self.displayTitle(for: tabController.window),
                subtitle: Self.subtitle(for: tabController),
                tabColor: (tabController.window as? TerminalWindow)?.tabColor ?? .none,
                isSelected: tabController === controller
            )
        }
    }

    private static func displayTitle(for window: NSWindow?) -> String {
        let title = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    private static func subtitle(for controller: TerminalController) -> String? {
        if let context = controller.tabState.repositoryContext {
            return "\(context.repositoryName) • \(context.branchName)"
        }

        if let workingDirectory = controller.tabState.workingDirectory, !workingDirectory.isEmpty {
            return URL(fileURLWithPath: workingDirectory).lastPathComponent
        }

        return nil
    }
}

@MainActor
private func openNewTab(from controller: TerminalController) {
    _ = TerminalController.newTab(controller.ghostty, from: controller.window)
}

struct VerticalTabBar: View {
    @ObservedObject var controller: TerminalController
    @StateObject private var dataSource: TabGroupDataSource

    init(controller: TerminalController) {
        self.controller = controller
        self._dataSource = StateObject(wrappedValue: TabGroupDataSource(controller: controller))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(dataSource.items) { item in
                        TerminalTabBarRow(item: item)
                    }
                }
                .padding(8)
            }

            Divider()

            VStack(spacing: 0) {
                TabBarActionButton(title: "New Tab", systemImage: "plus") {
                    openNewTab(from: controller)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("terminal-custom-tab-bar-vertical")
    }
}

private struct TerminalTabBarRow: View {
    let item: TerminalTabBarItem

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            tabColorIndicator

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    item.isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.75)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(item.isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            item.controller?.window?.makeKeyAndOrderFront(nil)
        }
        .contextMenu {
            Button("Rename Tab...") {
                renameTab()
            }

            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button {
                        setTabColor(color)
                    } label: {
                        Label {
                            Text(color.localizedName)
                        } icon: {
                            Image(nsImage: color.swatchImage(selected: item.tabColor == color))
                        }
                    }
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var tabColorIndicator: some View {
        Group {
            if let displayColor = item.tabColor.displayColor {
                Circle()
                    .fill(Color(displayColor))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 8, height: 8)
                    .opacity(0.6)
            }
        }
    }

    private var closeButton: some View {
        Group {
            if isHovering {
                Button {
                    item.controller?.closeTab(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
    }

    private func renameTab() {
        guard let controller = item.controller else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            controller.promptTabTitle()
        }
    }

    private func setTabColor(_ color: TerminalTabColor) {
        guard let window = item.controller?.window as? TerminalWindow else { return }
        window.tabColor = color
    }
}

private struct TabBarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
