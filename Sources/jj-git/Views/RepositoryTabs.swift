import SwiftUI

struct RepositoryTabs: View {
    @Bindable var workspace: Workspace
    @State private var frames: [String: CGRect] = [:]
    @GestureState private var drag: TabDrag?

    private struct TabDrag {
        let path: String
        let location: CGPoint?
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(workspace.library.tabs, id: \.self) { path in
                            let mounted = workspace.sessions[path] != nil
                            let name = URL(fileURLWithPath: path).lastPathComponent
                            HStack(spacing: 8) {
                                Button { workspace.select(path) } label: {
                                    HStack(spacing: 5) {
                                        if workspace.sessions[path]?.operation != nil {
                                            ProgressView().controlSize(.mini)
                                        }
                                        Text(name).lineLimit(1)
                                            .foregroundStyle(mounted ? Theme.foreground : Theme.badge)
                                    }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(name).accessibilityIdentifier("tab")
                                    .accessibilityValue(workspace.library.selectedPath == path ? "当前标签"
                                        : mounted ? "" : "未挂载")
                                    .accessibilityAddTraits(workspace.library.selectedPath == path ? .isSelected : [])
                                    .accessibilityHint(path)
                                    .accessibilityMenuActions(tabActions(path).flatMap(\.self))
                                    .simultaneousGesture(reorderGesture(path, reader: reader, width: proxy.size.width))
                                Button { workspace.close(path) } label: {
                                    Image(systemName: "xmark").font(.ui(-3))
                                }
                                .buttonStyle(.plain).help("关闭标签 ⌘W").accessibilityLabel("关闭 \(name)")
                                .disabled(workspace.sessions[path]?.operation != nil)
                            }
                            .padding(.horizontal, 12).frame(height: 32).id(path)
                            .background(workspace.library.selectedPath == path ? Theme.accent.opacity(0.12) : .clear)
                            .overlay(alignment: .bottom) {
                                if workspace.library.selectedPath == path {
                                    Theme.accent.frame(height: 2)
                                }
                            }
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TabFrames.self,
                                                       value: [path: geometry.frame(in: .named("repository-tabs"))])
                            })
                            .overlay(alignment: .leading) { insertionMark(path, trailing: false) }
                            .overlay(alignment: .trailing) { insertionMark(path, trailing: true) }
                            .opacity(drag?.path == path ? 0.6 : 1)
                            .help(mounted ? path : "未挂载，点击重新加载\n\(path)")
                            .contextMenu { MenuActionGroups(groups: tabActions(path)) }
                            ThemedDivider().frame(height: 18)
                        }
                    }
                    // 撑满可见宽度，标签右侧空白也能拖动 / 双击缩放窗口。
                    .frame(minWidth: proxy.size.width, alignment: .leading).windowDragArea()
                }.scrollIndicators(.hidden)
            }
        }.frame(height: 32).coordinateSpace(name: "repository-tabs")
            .onPreferenceChange(TabFrames.self) { frames = $0 }
    }

    private func reorderGesture(_ path: String, reader: ScrollViewProxy, width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("repository-tabs")))
            .updating($drag) { value, state, _ in
                if case let .second(true, movement) = value {
                    state = TabDrag(path: path, location: movement?.location)
                }
            }
            .onChanged { value in
                guard case let .second(true, movement?) = value,
                      (-16...48).contains(movement.location.y) else { return }
                let tabs = workspace.library.tabs
                if movement.location.x > width - 24,
                   let next = tabs.first(where: { (frames[$0]?.maxX ?? 0) > width + 1 }) {
                    reader.scrollTo(next, anchor: .trailing)
                } else if movement.location.x < 24,
                          let previous = tabs.last(where: { (frames[$0]?.minX ?? 0) < -1 }) {
                    reader.scrollTo(previous, anchor: .leading)
                }
            }
            .onEnded { value in
                guard case let .second(true, movement?) = value,
                      (-16...48).contains(movement.location.y) else { return }
                workspace.moveTab(path, to: destination(path, at: movement.location))
            }
    }

    private func destination(_ path: String, at location: CGPoint) -> Int {
        workspace.library.tabs.filter { $0 != path && (frames[$0]?.midX ?? .infinity) < location.x }.count
    }

    @ViewBuilder
    private func insertionMark(_ path: String, trailing: Bool) -> some View {
        if let drag, let location = drag.location, (-16...48).contains(location.y) {
            let others = workspace.library.tabs.filter { $0 != drag.path }
            let index = destination(drag.path, at: location)
            let anchor = index < others.count ? others[index] : others.last
            if anchor == path, trailing == (index == others.count) {
                Theme.accent.frame(width: 2).allowsHitTesting(false)
            }
        }
    }

    private func move(_ path: String, offset: Int) {
        guard let index = workspace.library.tabs.firstIndex(of: path) else { return }
        workspace.moveTab(path, to: index + offset)
    }

    private func tabActions(_ path: String) -> [[MenuAction]] {
        let tabs = workspace.library.tabs
        let index = tabs.firstIndex(of: path) ?? 0
        let left = Array(tabs[..<index]), right = Array(tabs[(index + 1)...])
        return [
            [
                MenuAction(title: "向左移动标签", enabled: index > 0) { move(path, offset: -1) },
                MenuAction(title: "向右移动标签", enabled: index < tabs.count - 1) { move(path, offset: 1) }
            ],
            [MenuAction(title: "关闭标签", enabled: workspace.sessions[path]?.operation == nil) {
                workspace.close(path)
            }],
            [
                MenuAction(title: "关闭其他标签", enabled: tabs.count > 1) {
                    workspace.close(left + right, keeping: path)
                },
                MenuAction(title: "关闭左侧标签", enabled: !left.isEmpty) { workspace.close(left, keeping: path) },
                MenuAction(title: "关闭右侧标签", enabled: !right.isEmpty) { workspace.close(right, keeping: path) }
            ]
        ]
    }
}

private struct TabFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
