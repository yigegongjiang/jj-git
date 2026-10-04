import SwiftUI

struct EmptyState: View {
    let title: String
    let symbol: String
    var detail = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.ui(1, weight: .semibold))
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NamePrompt: View {
    let title: String
    let initial: String
    let submit: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.ui(1, weight: .semibold))
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340).themed()
        .onAppear { name = initial }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submit(name)
        dismiss()
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 80)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭错误提示")
        }
        .font(.ui()).padding(8).background(Theme.orange.opacity(0.12))
    }
}

/// 隐藏标题栏后的顶部条：与窗口按钮同一行，左侧让出窗口按钮（实测右缘 70pt）。
struct WindowBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }.padding(.leading, 78).padding(.trailing, 10).frame(height: 32)
            .windowDragArea()
    }
}

extension View {
    /// 标题栏隐藏后由空白处接管：拖动移动窗口，双击按系统「双击窗口标题栏」设置缩放或最小化。
    /// SwiftUI 手势会让窗口无法拖动，因此用 AppKit 视图处理。
    func windowDragArea() -> some View {
        background(WindowDragArea())
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        DragView()
    }

    func updateNSView(_: NSView, context _: Context) {
    }

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(title).font(.ui(-1, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10).frame(height: 28).background(Theme.titleBar)
    }
}

extension EnvironmentValues {
    /// 分栏 / 窗口位置写入 state.json。NSHostingView 不继承外层环境，SplitPane 显式向各栏传递。
    @Entry var workspace: Workspace?
}

/// 可拖动分栏，位置写入 state.json `splits`，切换标签 / 页面 / 重启后保留。
/// SwiftUI HSplitView 首次布局把首栏撑到 maxWidth 且不记忆位置，因此用 NSSplitView。
/// 不用 NSSplitViewController：其约束会让嵌套在同向分栏里的分割线无法拖动。
/// 各栏内容在独立 NSHostingView 中求值：闭包内 MUST NOT 读取外层 @State（不会触发刷新），只传 Binding。
struct SplitPane<First: View, Second: View>: NSViewRepresentable {
    enum Pinned { case first, second }

    let name: String
    var vertical = false
    /// 窗口缩放时保持尺寸的一栏；nil 时两栏按比例缩放。`initial` 为它（nil 时为首栏）的默认尺寸。
    var pinned: Pinned? = .first
    let initial: CGFloat
    var minimum: (first: CGFloat, second: CGFloat) = (120, 120)
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    func makeNSView(context: Context) -> SplitPaneView {
        let workspace = context.environment.workspace
        let view = SplitPaneView()
        view.isVertical = !vertical
        view.dividerStyle = .thin
        view.delegate = view
        view.addArrangedSubview(Self.host(SplitPaneContent(workspace: workspace, content: first)))
        view.addArrangedSubview(Self.host(SplitPaneContent(workspace: workspace, content: second)))
        view.name = name
        view.workspace = workspace
        view.pinned = pinned == .second ? 1 : 0
        view.proportional = pinned == nil
        view.minimum = minimum
        view.size = workspace?.library.splits[name].map { CGFloat($0) } ?? initial
        return view
    }

    func updateNSView(_ view: SplitPaneView, context: Context) {
        let workspace = context.environment.workspace
        let panes = view.arrangedSubviews
        (panes[0] as? NSHostingView<SplitPaneContent<First>>)?.rootView =
            SplitPaneContent(workspace: workspace, content: first)
        (panes[1] as? NSHostingView<SplitPaneContent<Second>>)?.rootView =
            SplitPaneContent(workspace: workspace, content: second)
    }

    private static func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        // 尺寸由分栏决定，避免 SwiftUI 内容尺寸约束与拖动冲突。
        host.sizingOptions = []
        return host
    }
}

/// 闭包在分栏自己的 body 中执行，使其中读取的 @Observable 状态由该分栏追踪刷新。
struct SplitPaneContent<Content: View>: View {
    let workspace: Workspace?
    let content: () -> Content
    var body: some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity).themed().environment(\.workspace, workspace)
    }
}

final class SplitPaneView: NSSplitView, NSSplitViewDelegate {
    var name = ""
    weak var workspace: Workspace?
    var minimum: (first: CGFloat, second: CGFloat) = (0, 0)
    /// 保持尺寸的一栏；proportional 时为首栏，仅用于记录位置。
    var pinned = 0
    var proportional = false
    /// pinned 栏的尺寸：首次布局时放置，拖动结束后写回。
    var size: CGFloat = 0
    private var placed = false

    private var length: CGFloat {
        isVertical ? bounds.width : bounds.height
    }

    override var dividerColor: NSColor {
        Theme.nsBorder
    }

    override func layout() {
        super.layout()
        guard !placed, length > minimum.first + minimum.second + dividerThickness else { return }
        placed = true
        // 窗口比上次小时由 constrainMin/MaxCoordinate 收敛到最小尺寸以内。
        setPosition(pinned == 0 ? size : length - size - dividerThickness, ofDividerAt: 0)
    }

    /// NSSplitView 在 mouseDown 内跟踪分割线拖动，返回即拖动结束。
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let frame = arrangedSubviews[pinned].frame
        size = (isVertical ? frame.width : frame.height).rounded()
        workspace?.setSplit(name, size: Double(size))
    }

    /// 非 Auto Layout 下 holdingPriority 不生效，窗口缩放时由此固定 pinned 栏。
    func splitView(_: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        proportional || view !== arrangedSubviews[pinned]
    }

    func splitView(_: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        max(proposed, minimum.first)
    }

    func splitView(_: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        min(proposed, length - minimum.second - dividerThickness)
    }
}

/// 主窗口位置写入 state.json `window`，替代 SwiftUI 写入 UserDefaults 的自动保存。
struct WindowFrameKeeper: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context _: Context) -> KeeperView {
        let view = KeeperView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_: KeeperView, context _: Context) {
    }

    final class KeeperView: NSView {
        weak var workspace: Workspace?
        private var observers: [NSObjectProtocol] = []
        private var pending: Task<Void, Never>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            pending?.cancel()
            guard let window else { return }
            window.setFrameAutosaveName("")
            if let saved = workspace?.library.window {
                let frame = NSRect(x: saved.minX, y: saved.minY, width: saved.width, height: saved.height)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    window.setFrame(frame, display: true)
                }
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleSave() }
                })
            }
        }

        /// 拖动 / 缩放过程中连续触发，停止 0.5 秒后再写入。
        private func scheduleSave() {
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let frame = window?.frame else { return }
                workspace?.setWindowFrame(WindowFrame(
                    minX: frame.minX, minY: frame.minY, width: frame.width, height: frame.height
                ))
            }
        }
    }
}
