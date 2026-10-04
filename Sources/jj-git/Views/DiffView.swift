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
                        ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(entries) { entry in
                                    DiffFileSection(session: session, entry: entry, editable: editable,
                                                    wrap: wrap, width: width, viewport: geometry.size.width)
                                        .id(entry.id)
                                }
                            }.frame(width: width, alignment: .leading).padding(.bottom, 12)
                        }
                        .onChange(of: session.diffScrollRequest) { _, _ in
                            if let value = session.diffScrollID {
                                proxy.scrollTo(value, anchor: .top)
                            }
                        }
                        .onChange(of: entries.map(\.id)) { _, _ in
                            if let first = entries.first {
                                proxy.scrollTo(first.id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DiffFileSection: View {
    @Bindable var session: RepositorySession
    let entry: FileDiff
    let editable: Bool
    let wrap: Bool
    let width: CGFloat
    let viewport: CGFloat
    @State private var anchor: Int?
    @State private var discarding: Set<Int> = []

    private var focused: Bool {
        session.selectedFile?.path == entry.target.path && session.selectedStaged == entry.target.staged
    }

    private var selection: Set<Int> {
        focused ? session.selectedLines : []
    }

    private var canEdit: Bool {
        editable && session.operation == nil && entry.diff.partialRestriction == nil
            && entry.target.file?.conflicted == false && entry.target.file?.submodule == false
    }

    private var canDiscard: Bool {
        canEdit && !entry.target.staged && entry.target.file?.untracked == false
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: entry.target.path + (editable ? entry.target.staged ? " · 已暂存" : " · 未暂存" : "")) {
                if editable {
                    if canDiscard {
                        Button("放弃选中行") { discarding = selection }
                            .buttonStyle(.borderless).font(.ui(-1)).disabled(selection.isEmpty)
                    }
                    Button(entry.target.staged ? "取消选中行暂存" : "暂存选中行") { apply(selection) }
                        .buttonStyle(.borderless).font(.ui(-1)).disabled(!canEdit || selection.isEmpty)
                }
            }.frame(width: viewport).frame(width: width, alignment: .leading)
            if entry.diff.binary {
                Text("二进制文件").font(.ui()).foregroundStyle(.secondary).padding(12)
            } else if entry.diff.hunks.isEmpty {
                Text("无文本差异\n" + String(entry.diff.headers.joined(separator: "\n").prefix(500)))
                    .font(.mono(-1)).foregroundStyle(.secondary).padding(12)
            } else {
                if let restriction = entry.diff.partialRestriction {
                    Text(restriction).font(.ui(-2)).foregroundStyle(.secondary).padding(6)
                }
                ForEach(entry.diff.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(hunk.lines) { line in
                        DiffLineView(line: line, selected: selection.contains(line.id),
                                     selectable: canEdit && line.changed, wrap: wrap) { toggle(line) }
                            .frame(width: width, alignment: .leading)
                    }
                }
            }
        }
        .confirmationDialog("放弃选中的变更？", isPresented: Binding(
            get: { !discarding.isEmpty }, set: {
                if !$0 {
                    discarding = []
                }
            }
        ), titleVisibility: .visible) {
            Button("放弃", role: .destructive) {
                if let file = entry.target.file {
                    session.perform(.discardLines(file, diff: entry.diff, lines: discarding), title: "放弃变更")
                }
                discarding = []
            }
            Button("取消", role: .cancel) { discarding = [] }
        } message: {
            Text("工作区中的这些行将恢复为暂存区内容，无法撤销。")
        }
        .onChange(of: focused) { _, value in
            if !value {
                anchor = nil
            }
        }
        .onChange(of: entry.diff.raw) { _, _ in anchor = nil; discarding = [] }
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 12) {
            Text(hunk.header).font(.mono(-1)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 16)
            if editable {
                if canDiscard {
                    Button("放弃此块") { discarding = hunk.changeIDs }
                        .buttonStyle(.borderless).font(.ui(-1))
                }
                Button(entry.target.staged ? "取消此块暂存" : "暂存此块") { apply(hunk.changeIDs) }
                    .buttonStyle(.borderless).font(.ui(-1)).disabled(!canEdit)
            }
        }.padding(.horizontal, 8).frame(width: viewport, height: 28)
            .frame(width: width, alignment: .leading).background(Theme.titleBar)
    }

    private func toggle(_ line: DiffLine) {
        session.focusDiff(entry)
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let anchor {
            let range = min(anchor, line.id)...max(anchor, line.id)
            session.selectedLines.formUnion(entry.diff.changeIDs.filter { range.contains($0) })
        } else if session.selectedLines.contains(line.id) {
            session.selectedLines.remove(line.id)
        } else {
            session.selectedLines.insert(line.id)
        }
        anchor = line.id
    }

    private func apply(_ selection: Set<Int>) {
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
