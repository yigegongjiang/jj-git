import AppKit
import SwiftUI

struct DiffView: View {
    @Bindable var session: RepositorySession
    let editable: Bool
    @AppStorage("jj-git.diffWrap") private var wrap = true

    private var entries: [FileDiff] {
        if !session.fileDiffs.isEmpty {
            return session.fileDiffs
        }
        guard let diff = session.diff else { return [] }
        let target = DiffTarget(path: editable ? session.selectedFile?.path ?? "差异"
            : session.selectedCommitFile?.path ?? "差异", file: editable ? session.selectedFile : nil,
            staged: editable && session.selectedStaged)
        return [FileDiff(target: target, diff: diff)]
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeading(title: session.fileDiffs.isEmpty ? "差异" : "全部差异 · \(entries.count)") {
                if session.diffFallback {
                    Text("全量预览未完成，显示单文件").font(.ui(-2)).foregroundStyle(.secondary)
                }
                Toggle("自动换行", isOn: $wrap).toggleStyle(.checkbox).font(.ui(-1))
            }
            if session.loadingDiff {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyState(title: "无差异", symbol: "doc.text.magnifyingglass")
            } else {
                GeometryReader { geometry in
                    let columns = entries.map { $0.diff.maxColumns }.max() ?? 0
                    let width = wrap ? geometry.size.width
                        : max(geometry.size.width, DiffLineView.width(columns: columns))
                    ScrollViewReader { proxy in
                        let content = DiffContent(session: session, entries: entries, editable: editable,
                                                  wrap: wrap, width: width, viewport: geometry.size.width)
                            .frame(width: width, height: geometry.size.height, alignment: .leading)
                        // 纵向滚动由 List 负责；不换行时外层只承担横向滚动。
                        Group {
                            if wrap {
                                content
                            } else {
                                ScrollView(.horizontal) { content }
                            }
                        }
                        .onChange(of: session.diffScrollRequest) { _, _ in
                            if let value = session.diffScrollID {
                                proxy.scrollTo(DiffRow.RowID(file: value, offset: 0), anchor: .top)
                            }
                        }
                        .onChange(of: entries.map(\.id)) { _, _ in
                            if let first = entries.first {
                                proxy.scrollTo(DiffRow.RowID(file: first.id, offset: 0), anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DiffRow: Identifiable {
    struct RowID: Hashable {
        let file: String
        let offset: Int
    }

    enum Content {
        case file
        case message(String)
        case hunk(DiffHunk)
        case line(DiffLine)
    }

    let id: RowID
    let entry: FileDiff
    let content: Content

    static func make(_ entry: FileDiff) -> [Self] {
        var contents: [Content] = [.file]
        if entry.diff.binary {
            contents.append(.message("二进制文件"))
        } else if entry.diff.hunks.isEmpty {
            contents.append(.message("无文本差异\n" + String(entry.diff.headers.joined(separator: "\n").prefix(500))))
        } else {
            if let restriction = entry.diff.partialRestriction {
                contents.append(.message(restriction))
            }
            for hunk in entry.diff.hunks {
                contents.append(.hunk(hunk))
                contents.append(contentsOf: hunk.lines.map(Content.line))
            }
        }
        return contents.enumerated().map {
            Self(id: RowID(file: entry.id, offset: $0.offset), entry: entry, content: $0.element)
        }
    }
}

/// 扁平行仅在差异内容变化时重建；选择行等状态变化不重复展开全部行。
private final class DiffRows {
    private var key: [DiffTarget] = []
    private var raws: [String] = []
    private var cached: [DiffRow] = []

    func rows(for entries: [FileDiff]) -> [DiffRow] {
        let key = entries.map(\.target)
        let raws = entries.map(\.diff.raw)
        if key != self.key || raws != self.raws {
            self.key = key
            self.raws = raws
            cached = entries.flatMap(DiffRow.make)
        }
        return cached
    }
}

private struct DiffContent: View {
    @Bindable var session: RepositorySession
    let entries: [FileDiff]
    let editable: Bool
    let wrap: Bool
    let width: CGFloat
    let viewport: CGFloat
    @State private var rows = DiffRows()
    @State private var anchor: (file: String, line: Int)?
    @State private var discarding: DiscardSelection?

    private struct DiscardSelection {
        let entry: FileDiff
        let lines: Set<Int>
    }

    var body: some View {
        List {
            ForEach(rows.rows(for: entries)) { row in
                // 文件、块、行扁平化，保持每项一个视图，使 List 按行复用。
                VStack(alignment: .leading, spacing: 0) {
                    switch row.content {
                    case .file:
                        fileHeader(row.entry)
                    case let .message(message):
                        Text(message).font(.mono(-1)).foregroundStyle(.secondary).padding(12)
                    case let .hunk(hunk):
                        hunkHeader(hunk, entry: row.entry)
                    case let .line(line):
                        DiffLineView(line: line, selected: selection(row.entry).contains(line.id),
                                     selectable: canEdit(row.entry) && line.changed, wrap: wrap) {
                            toggle(line, entry: row.entry)
                        }
                    }
                }.frame(width: width, alignment: .leading)
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .confirmationDialog("放弃选中的变更？", isPresented: Binding(
            get: { discarding != nil }, set: {
                if !$0 {
                    discarding = nil
                }
            }
        ), titleVisibility: .visible) {
            Button("放弃", role: .destructive) {
                if let discarding, let file = discarding.entry.target.file {
                    session.perform(.discardLines(file, diff: discarding.entry.diff, lines: discarding.lines),
                                    title: "放弃变更")
                }
                discarding = nil
            }
            Button("取消", role: .cancel) { discarding = nil }
        } message: {
            Text("工作区中的这些行将恢复为暂存区内容，无法撤销。")
        }
        .onChange(of: session.selectedFile?.path) { _, _ in resetAnchorIfUnfocused() }
        .onChange(of: session.selectedStaged) { _, _ in resetAnchorIfUnfocused() }
        .onChange(of: entries.map(\.diff.raw)) { _, _ in anchor = nil; discarding = nil }
    }

    private func resetAnchorIfUnfocused() {
        let focused = DiffTarget(path: session.selectedFile?.path ?? "", staged: session.selectedStaged).id
        if anchor?.file != focused {
            anchor = nil
        }
    }

    private func selection(_ entry: FileDiff) -> Set<Int> {
        session.selectedFile?.path == entry.target.path && session.selectedStaged == entry.target.staged
            ? session.selectedLines : []
    }

    private func canEdit(_ entry: FileDiff) -> Bool {
        editable && session.operation == nil && entry.diff.partialRestriction == nil
            && entry.target.file?.conflicted == false && entry.target.file?.submodule == false
    }

    private func canDiscard(_ entry: FileDiff) -> Bool {
        canEdit(entry) && !entry.target.staged && entry.target.file?.untracked == false
    }

    private func fileHeader(_ entry: FileDiff) -> some View {
        SectionHeading(title: entry.target.path + (editable ? entry.target.staged ? " · 已暂存" : " · 未暂存" : "")) {
            if editable {
                if canDiscard(entry) {
                    Button("放弃选中行") { discarding = DiscardSelection(entry: entry, lines: selection(entry)) }
                        .buttonStyle(.borderless).font(.ui(-1)).disabled(selection(entry).isEmpty)
                }
                Button(entry.target.staged ? "取消选中行暂存" : "暂存选中行") { apply(selection(entry), entry: entry) }
                    .buttonStyle(.borderless).font(.ui(-1)).disabled(!canEdit(entry) || selection(entry).isEmpty)
            }
        }.frame(width: viewport).frame(width: width, alignment: .leading)
    }

    private func hunkHeader(_ hunk: DiffHunk, entry: FileDiff) -> some View {
        HStack(spacing: 12) {
            Text(hunk.header).font(.mono(-1)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 16)
            if editable {
                if canDiscard(entry) {
                    Button("放弃此块") { discarding = DiscardSelection(entry: entry, lines: hunk.changeIDs) }
                        .buttonStyle(.borderless).font(.ui(-1))
                }
                Button(entry.target.staged ? "取消此块暂存" : "暂存此块") { apply(hunk.changeIDs, entry: entry) }
                    .buttonStyle(.borderless).font(.ui(-1)).disabled(!canEdit(entry))
            }
        }.padding(.horizontal, 8).frame(width: viewport, height: 28)
            .frame(width: width, alignment: .leading).background(Theme.titleBar)
    }

    private func toggle(_ line: DiffLine, entry: FileDiff) {
        session.focusDiff(entry)
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let anchor, anchor.file == entry.id {
            let range = min(anchor.line, line.id)...max(anchor.line, line.id)
            session.selectedLines.formUnion(entry.diff.changeIDs.filter { range.contains($0) })
        } else if session.selectedLines.contains(line.id) {
            session.selectedLines.remove(line.id)
        } else {
            session.selectedLines.insert(line.id)
        }
        anchor = (entry.id, line.id)
    }

    private func apply(_ selection: Set<Int>, entry: FileDiff) {
        guard let file = entry.target.file else { return }
        session.perform(.partial(file, staged: entry.target.staged, diff: entry.diff, lines: selection),
                        title: entry.target.staged ? "取消部分暂存" : "部分暂存")
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let selected: Bool
    let selectable: Bool
    let wrap: Bool
    let toggle: () -> Void

    /// 勾选 24 + 行号 40×2 + 标记 25 + 截断 / 末尾换行提示与留白 200。
    static func width(columns: Int) -> CGFloat {
        let typography = Typography.shared
        let font = typography.font(mono: true, size: typography.editorFontSize, weight: .regular)
        return ceil(CGFloat(columns) * ("0" as NSString).size(withAttributes: [.font: font]).width) + 329
    }

    private var tint: Color {
        line.kind == "+" ? Theme.added : line.kind == "-" ? Theme.deleted : .clear
    }

    var body: some View {
        let typography = Typography.shared
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if selectable {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Theme.foreground : Theme.foreground.opacity(0.5))
                }.buttonStyle(.plain).frame(width: 24)
                    .accessibilityLabel("选择差异行 \(line.newLine ?? line.oldLine ?? 0)")
            } else {
                Color.clear.frame(width: 24, height: 1)
            }
            Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Text(String(line.kind))
                .foregroundStyle(line.changed ? Theme.foreground : Theme.foreground.opacity(0.5))
                .frame(width: 25)
            if wrap {
                Text(line.display).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line.display).lineLimit(1).fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
            }
            if line.noNewline {
                Text("  ⏎ 无末尾换行").foregroundStyle(.tertiary).fixedSize()
            }
        }
        // 换行时多行内容按自然行高展开，上下各补一半间距；单行与不换行时行高一致。
        .font(.code()).padding(.vertical, wrap ? typography.diffLineSpacing / 2 : 0)
        .frame(maxWidth: .infinity, minHeight: typography.diffLineHeight,
               maxHeight: wrap ? nil : typography.diffLineHeight, alignment: .leading)
        .background(tint)
        // 增删行底色与强调色相同，选中改用提亮覆盖层区分。
        .overlay(selected ? Theme.foreground.opacity(0.25) : .clear)
    }
}
