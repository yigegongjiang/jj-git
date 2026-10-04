import AppKit
import SwiftUI

struct DiffView: View {
    @Bindable var session: RepositorySession
    let editable: Bool
    @State private var anchor: Int?
    @State private var discarding: Set<Int> = []
    /// 全局偏好：历史与本地变更共用；默认自动换行。
    @AppStorage("jj-git.diffWrap") private var wrap = true

    private var canEdit: Bool {
        editable && session.operation == nil && session.diff?.partialRestriction == nil
            && session.selectedFile?.conflicted == false && session.selectedFile?.submodule == false
    }

    /// 只有未暂存的已跟踪文件可按行放弃；未跟踪文件在文件列表整体放弃。
    private var canDiscard: Bool {
        canEdit && !session.selectedStaged && session.selectedFile?.untracked == false
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeading(title: editable ? session.selectedFile?.path ?? "差异" : session.selectedCommitFile?
                .path ?? "差异") {
                    Toggle("自动换行", isOn: $wrap).toggleStyle(.checkbox).font(.ui(-1))
                    if editable {
                        if canDiscard {
                            Button("放弃选中行") { discarding = session.selectedLines }
                                .buttonStyle(.borderless).font(.ui(-1))
                                .disabled(session.selectedLines.isEmpty)
                        }
                        Button(session.selectedStaged ? "取消选中行暂存" : "暂存选中行") { apply(session.selectedLines) }
                            .buttonStyle(.borderless).font(.ui(-1))
                            .disabled(!canEdit || session.selectedLines.isEmpty)
                    }
                }
            if session.loadingDiff {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = session.diff {
                if diff.binary {
                    EmptyState(title: "二进制文件", symbol: "doc", detail: "可通过文件列表暂存或取消暂存。")
                } else if diff.hunks.isEmpty {
                    EmptyState(
                        title: "无文本差异",
                        symbol: "doc.text",
                        detail: String(diff.headers.joined(separator: "\n").prefix(500))
                    )
                } else {
                    diffContent(diff)
                }
            } else {
                EmptyState(title: "选择文件查看差异", symbol: "doc.text.magnifyingglass")
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
                if let file = session.selectedFile, let diff = session.diff {
                    session.perform(.discardLines(file, diff: diff, lines: discarding), title: "放弃变更")
                }
                discarding = []
            }
            Button("取消", role: .cancel) { discarding = [] }
        } message: {
            Text("工作区中的这些行将恢复为暂存区内容，无法撤销。")
        }
    }

    private func diffContent(_ diff: TextDiff) -> some View {
        VStack(spacing: 0) {
            if let restriction = diff.partialRestriction {
                Text(restriction).font(.ui(-2)).foregroundStyle(.secondary).padding(6)
            }
            GeometryReader { geometry in
                // 换行时宽度跟随视口，行高随内容变化；不换行时固定为最长行宽度以便横向滚动。
                let width = wrap ? geometry.size.width
                    : max(DiffLineView.width(columns: diff.maxColumns), geometry.size.width)
                ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            HStack(spacing: 12) {
                                Text(hunk.header).font(.mono(-1))
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 16)
                                if editable {
                                    if canDiscard {
                                        Button("放弃此块") { discarding = hunk.changeIDs }
                                            .buttonStyle(.borderless).font(.ui(-1))
                                    }
                                    Button(session.selectedStaged ? "取消此块暂存" : "暂存此块") { apply(hunk.changeIDs) }
                                        .buttonStyle(.borderless).font(.ui(-1)).disabled(!canEdit)
                                }
                            }.padding(.horizontal, 8).frame(width: geometry.size.width, height: 28)
                                .frame(width: width, alignment: .leading).background(Theme.titleBar)
                            ForEach(hunk.lines) { line in
                                DiffLineView(line: line, selected: session.selectedLines.contains(line.id),
                                             selectable: canEdit && line.changed, wrap: wrap) { toggle(line, in: diff) }
                                    .frame(width: width, alignment: .leading)
                            }
                        }
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// 单击切换一行；按住 Shift 选中与上次点击之间的全部变更行。
    private func toggle(_ line: DiffLine, in diff: TextDiff) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let anchor {
            let range = min(anchor, line.id)...max(anchor, line.id)
            session.selectedLines.formUnion(diff.changeIDs.filter { range.contains($0) })
        } else if session.selectedLines.contains(line.id) {
            session.selectedLines.remove(line.id)
        } else {
            session.selectedLines.insert(line.id)
        }
        anchor = line.id
    }

    private func apply(_ selection: Set<Int>) {
        guard let file = session.selectedFile, let diff = session.diff else { return }
        session.perform(.partial(file, staged: session.selectedStaged, diff: diff, lines: selection),
                        title: session.selectedStaged ? "取消部分暂存" : "部分暂存")
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

    private var height: CGFloat {
        (Typography.shared.editorFontSize * 1.75).rounded()
    }

    private var tint: Color {
        line.kind == "+" ? Theme.added : line.kind == "-" ? Theme.deleted : .clear
    }

    var body: some View {
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
        .font(.code()).padding(.vertical, wrap ? 3 : 0)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: wrap ? nil : height, alignment: .leading)
        .background(tint)
        // 增删行底色与强调色相同，选中改用提亮覆盖层区分。
        .overlay(selected ? Theme.foreground.opacity(0.25) : .clear)
    }
}
