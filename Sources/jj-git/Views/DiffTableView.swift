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

/// 全部差异列表：NSTableView 复用行视图，行高预先计算查表，滚动时不做 SwiftUI 布局。
struct DiffTableView: NSViewRepresentable {
    let entries: [FileDiff]
    let wrap: Bool
    let reveal: DiffReveal?
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
    /// 换行模式下尚未实测、使用占位高度的行；首屏同步实测，其余分片补算。
    private var pending = IndexSet()
    private var textWidth: CGFloat = 0
    private var measureGeneration = 0
    private var reveal: DiffReveal?
    /// 待滚动到的行；布局推迟时由 layoutWidth 在加载后执行。
    private var scrollTarget: Int?

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
        if idsChanged || view.reveal != reveal {
            reveal = view.reveal
            scrollToReveal(fallback: idsChanged)
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
        let anchor = visibleAnchor()
        column.width = wrap ? width : max(width, metrics.contentWidth(columns: columns))
        textWidth = column.width - DiffMetrics.gutter
        measureGeneration += 1
        pending = []
        heights = rows.indices.map { index in
            switch rows[index].content {
            case .file, .hunk: return DiffMetrics.headerHeight
            case let .message(text): return metrics.textHeight(
                    NSAttributedString(string: text, attributes: [.font: metrics.small]), width: width - 24
                ) + 24
            case let .line(line):
                guard wrap else { return metrics.rowHeight }
                if let height = metrics.singleRowHeight(line, width: textWidth) {
                    return height
                }
                pending.insert(index)
                return metrics.estimatedHeight(line, width: textWidth)
            }
        }
        if reload {
            table.reloadData()
        } else {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            refreshVisibleRows()
        }
        if let target = scrollTarget {
            scrollTarget = nil
            scroll(to: target)
        } else {
            restore(anchor)
        }
        measureVisible()
        scheduleRefine()
    }

    private func scroll(to row: Int) {
        guard row < rows.count else { return }
        scroll(top: table.rect(ofRow: row).minY, left: 0)
        measureVisible()
    }

    private func scroll(top: CGFloat, left: CGFloat? = nil) {
        table.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: left ?? clip.bounds.minX, y: min(max(0, top), maxY)))
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

/// 文件定位：内容集合变化（如全部差异读取完成）或新请求时滚动到该文件头，否则回到顶部。
extension DiffTableCoordinator {
    private func scrollToReveal(fallback: Bool) {
        let row = reveal.flatMap { reveal in
            rows.firstIndex {
                if case .file = $0.content {
                    $0.entry.id == reveal.id
                } else {
                    false
                }
            }
        }
        guard let target = row ?? (fallback ? 0 : nil) else { return }
        if needsReload || table.numberOfRows != rows.count {
            scrollTarget = target
        } else {
            scroll(to: target)
        }
    }
}

/// 换行行高渐进实测：首屏同步，其余按时间片补算，首屏耗时与差异总行数无关。
extension DiffTableCoordinator {
    /// 首个可见行及其上沿到视口顶部的偏移；行高重算后据此恢复，内容不随占位高度跳动。
    private func visibleAnchor() -> (row: Int, offset: CGFloat)? {
        let row = table.rows(in: table.visibleRect).location
        guard row != NSNotFound, row < table.numberOfRows else { return nil }
        return (row, table.visibleRect.minY - table.rect(ofRow: row).minY)
    }

    private func restore(_ anchor: (row: Int, offset: CGFloat)?) {
        guard let anchor, anchor.row < rows.count else { return }
        scroll(top: table.rect(ofRow: anchor.row).minY + anchor.offset)
    }

    /// 实测可见行；实测高度可能小于占位，使更多行进入视口，循环直到视口内全部实测。
    private func measureVisible() {
        for _ in 0..<16 {
            guard let range = Range(table.rows(in: table.visibleRect)) else { return }
            let visible = pending.intersection(IndexSet(integersIn: range))
            guard !visible.isEmpty else { return }
            let changed = IndexSet(visible.filter { measure($0) != 0 })
            if !changed.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }
    }

    private func measure(_ index: Int) -> CGFloat {
        pending.remove(index)
        guard case let .line(line) = rows[index].content else { return 0 }
        let height = metrics.wrappedHeight(line, width: textWidth)
        let delta = height - heights[index]
        heights[index] = height
        return delta
    }

    /// 每片约 8ms 后让出主线程，保证滚动与输入响应；内容 / 宽度变化或视图释放后停止。
    private func scheduleRefine() {
        guard !pending.isEmpty else { return }
        let generation = measureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            self?.refine(generation)
        }
    }

    private func refine(_ generation: Int) {
        guard generation == measureGeneration else { return }
        measureVisible()
        let first = table.rows(in: table.visibleRect).location
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(8))
        var changed = IndexSet()
        var above: CGFloat = 0
        while let index = pending.first, ContinuousClock.now < deadline {
            let delta = measure(index)
            if delta != 0 {
                changed.insert(index)
                if index < first {
                    above += delta
                }
            }
        }
        if !changed.isEmpty {
            let anchor = above != 0 ? visibleAnchor() : nil
            table.noteHeightOfRows(withIndexesChanged: changed)
            restore(anchor)
        }
        scheduleRefine()
    }
}
