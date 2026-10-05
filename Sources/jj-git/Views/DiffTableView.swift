import AppKit
import SwiftUI

/// 文件头 / 块头 / 说明 / 差异行扁平化后的一行。
struct DiffRow {
    enum Content {
        case file
        case message(String)
        case hunk(DiffHunk)
        case line(DiffLine)
    }

    let entry: FileDiff
    let content: Content

    static func make(_ entry: FileDiff) -> [Self] {
        var rows = [Self(entry: entry, content: .file)]
        if entry.diff.binary {
            rows.append(Self(entry: entry, content: .message("二进制文件")))
        } else if entry.diff.hunks.isEmpty {
            let headers = String(entry.diff.headers.joined(separator: "\n").prefix(500))
            rows.append(Self(entry: entry, content: .message("无文本差异\n" + headers)))
        } else {
            if let restriction = entry.diff.partialRestriction {
                rows.append(Self(entry: entry, content: .message(restriction)))
            }
            for hunk in entry.diff.hunks {
                rows.append(Self(entry: entry, content: .hunk(hunk)))
                rows += hunk.lines.map { Self(entry: entry, content: .line($0)) }
            }
        }
        return rows
    }
}

/// 选择与操作状态；在 SwiftUI body 中读取后按值传入，变化时只重配可见行。
struct DiffTableState: Equatable {
    var editable = false
    var focused: String?
    var selectedLines: Set<Int> = []
    var busy = false
}

struct DiffTableActions {
    let toggle: (FileDiff, DiffLine, _ extend: Bool) -> Void
    let apply: (FileDiff, Set<Int>) -> Void
    let discard: (FileDiff, Set<Int>) -> Void
}

/// 全部差异列表：NSTableView 复用行视图，行高预先计算查表，滚动时不做 SwiftUI 布局。
struct DiffTableView: NSViewRepresentable {
    let entries: [FileDiff]
    let wrap: Bool
    let state: DiffTableState
    let actions: DiffTableActions

    func makeCoordinator() -> DiffTableCoordinator {
        DiffTableCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    /// 填满父容器；默认 fittingSize 会测量整个表格。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSScrollView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

@MainActor
final class DiffTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = DiffScrollView()
    private let table = NSTableView()
    private let column = NSTableColumn(identifier: .init("diff"))
    private var metrics = DiffMetrics()
    private var rows: [DiffRow] = []
    private var heights: [CGFloat] = []
    private var key: [DiffTarget] = []
    private var raws: [String] = []
    private var wrap = false
    private var columns = 0
    private var laidOutWidth: CGFloat = -1
    private var needsReload = false
    private var state = DiffTableState()
    private var actions: DiffTableActions?

    private var viewport: CGFloat {
        scrollView.contentSize.width
    }

    func makeScrollView() -> NSScrollView {
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.onResize = { [weak self] in self?.layoutWidth() }
        return scrollView
    }

    func update(_ view: DiffTableView) {
        actions = view.actions
        let keys = view.entries.map(\.target)
        let texts = view.entries.map(\.diff.raw)
        let contentChanged = keys != key || texts != raws
        let idsChanged = keys.map(\.id) != key.map(\.id)
        if contentChanged || view.wrap != wrap {
            key = keys
            raws = texts
            wrap = view.wrap
            state = view.state
            rows = view.entries.flatMap(DiffRow.make)
            columns = view.entries.map(\.diff.maxColumns).max() ?? 0
            scrollView.hasHorizontalScroller = !wrap
            laidOutWidth = -1
            layoutWidth(reload: true)
        } else if view.state != state {
            state = view.state
            refreshVisibleRows()
        }
        if idsChanged {
            scroll(to: 0)
        }
    }

    /// 宽度变化时重算列宽与行高；拖动缩放窗口期间推迟到结束，避免逐帧测量。
    private func layoutWidth(reload: Bool = false) {
        let width = viewport
        needsReload = needsReload || reload
        // 首次 update 时尚未布局，宽度为 0：推迟到 tile 拿到宽度后再加载。
        guard width > 0, needsReload || width != laidOutWidth else { return }
        if !needsReload, scrollView.inLiveResize {
            // 拖动缩放期间只跟随列宽，行高在缩放结束后统一重算。
            column.width = wrap ? width : max(width, metrics.contentWidth(columns: columns))
            return
        }
        let reload = needsReload
        needsReload = false
        laidOutWidth = width
        column.width = wrap ? width : max(width, metrics.contentWidth(columns: columns))
        let textWidth = column.width - DiffMetrics.gutter
        heights = rows.map { row in
            switch row.content {
            case .file, .hunk: DiffMetrics.headerHeight
            case let .message(text): metrics.textHeight(
                    NSAttributedString(string: text, attributes: [.font: metrics.small]), width: width - 24
                ) + 24
            case let .line(line): wrap ? metrics.wrappedHeight(line, width: textWidth) : metrics.rowHeight
            }
        }
        if reload {
            table.reloadData()
        } else {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            refreshVisibleRows()
        }
    }

    private func scroll(to row: Int) {
        guard row < rows.count else { return }
        table.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(table.rect(ofRow: row).minY, maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func refreshVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<visible.location + visible.length {
            if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                configure(view, row: row)
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < heights.count ? heights[row] : metrics.rowHeight
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    /// 行内子视图合并绘制到行视图的单个图层，减少每帧提交的图层数。
    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("diff.row")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableRowView {
            return view
        }
        let view = NSTableRowView()
        view.identifier = identifier
        view.wantsLayer = true
        view.canDrawSubviewsIntoLayer = true
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier: NSUserInterfaceItemIdentifier = switch rows[row].content {
        case .file: DiffFileCell.identifier
        case .hunk: DiffHunkCell.identifier
        case .message: DiffMessageCell.identifier
        case .line: DiffLineCell.identifier
        }
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) ?? {
            let view: NSView = switch rows[row].content {
            case .file: DiffFileCell()
            case .hunk: DiffHunkCell()
            case .message: DiffMessageCell()
            case .line: DiffLineCell()
            }
            view.identifier = identifier
            return view
        }()
        configure(view, row: row)
        return view
    }

    private func canEdit(_ entry: FileDiff) -> Bool {
        state.editable && !state.busy && entry.diff.partialRestriction == nil
            && entry.target.file?.conflicted == false && entry.target.file?.submodule == false
    }

    private func canDiscard(_ entry: FileDiff) -> Bool {
        canEdit(entry) && !entry.target.staged && entry.target.file?.untracked == false
    }

    private func selection(_ entry: FileDiff) -> Set<Int> {
        state.focused == entry.id ? state.selectedLines : []
    }

    private func configure(_ view: NSView, row: Int) {
        let entry = rows[row].entry
        let actions = actions
        switch rows[row].content {
        case .file:
            guard let cell = view as? DiffFileCell else { return }
            let selected = selection(entry)
            var buttons: [DiffButton] = []
            if state.editable {
                if canDiscard(entry) {
                    buttons.append(DiffButton(title: "放弃选中行", enabled: !selected.isEmpty) {
                        actions?.discard(entry, selected)
                    })
                }
                buttons.append(DiffButton(title: entry.target.staged ? "取消选中行暂存" : "暂存选中行",
                                          enabled: canEdit(entry) && !selected.isEmpty) {
                        actions?.apply(entry, selected)
                    })
            }
            let suffix = state.editable ? entry.target.staged ? " · 已暂存" : " · 未暂存" : ""
            cell.configure(title: entry.target.path + suffix, buttons: buttons, metrics: metrics, viewport: viewport)
        case let .hunk(hunk):
            guard let cell = view as? DiffHunkCell else { return }
            var buttons: [DiffButton] = []
            if state.editable {
                if canDiscard(entry) {
                    buttons.append(DiffButton(title: "放弃此块", enabled: true) { actions?.discard(entry, hunk.changeIDs) })
                }
                buttons.append(DiffButton(title: entry.target.staged ? "取消此块暂存" : "暂存此块",
                                          enabled: canEdit(entry)) { actions?.apply(entry, hunk.changeIDs) })
            }
            cell.configure(title: hunk.header, buttons: buttons, metrics: metrics, viewport: viewport)
        case let .message(text):
            (view as? DiffMessageCell)?.configure(text, metrics: metrics)
        case let .line(line):
            let content = DiffLineCell.Content(line: line, text: metrics.text(line),
                                               selected: selection(entry).contains(line.id),
                                               selectable: canEdit(entry) && line.changed, wrap: wrap)
            (view as? DiffLineCell)?.configure(content, metrics: metrics) { actions?.toggle(entry, line, $0) }
        }
    }
}
