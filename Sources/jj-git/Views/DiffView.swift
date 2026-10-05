import AppKit
import SwiftUI

struct DiffView: View {
    @Bindable var session: RepositorySession
    let editable: Bool
    @AppStorage("jj-git.diffWrap") private var wrap = true
    @State private var anchor: (file: String, line: Int)?
    @State private var discarding: DiscardSelection?

    private struct DiscardSelection {
        let entry: FileDiff
        let lines: Set<Int>
    }

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
                DiffTableView(entries: entries, wrap: wrap, state: state, actions: actions)
            }
        }
        .dismissConfirmationOnBackgroundClick(isPresented: Binding(
            get: { discarding != nil }, set: {
                if !$0 {
                    discarding = nil
                }
            }
        ))
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
        .onChange(of: focused) { _, value in
            if anchor?.file != value {
                anchor = nil
            }
        }
        .onChange(of: entries.map(\.diff.raw)) { _, _ in anchor = nil; discarding = nil }
    }

    private var focused: String? {
        editable ? DiffTarget(path: session.selectedFile?.path ?? "", staged: session.selectedStaged).id : nil
    }

    private var state: DiffTableState {
        DiffTableState(editable: editable, focused: focused, selectedLines: editable ? session.selectedLines : [],
                       busy: session.operation != nil)
    }

    private var actions: DiffTableActions {
        DiffTableActions(toggle: toggle, apply: { entry, lines in
            guard let file = entry.target.file else { return }
            session.perform(.partial(file, staged: entry.target.staged, diff: entry.diff, lines: lines),
                            title: entry.target.staged ? "取消部分暂存" : "部分暂存")
        }, discard: { entry, lines in
            discarding = DiscardSelection(entry: entry, lines: lines)
        })
    }

    private func toggle(_ entry: FileDiff, _ line: DiffLine, extend: Bool) {
        session.focusDiff(entry)
        if extend, let anchor, anchor.file == entry.id {
            let range = min(anchor.line, line.id)...max(anchor.line, line.id)
            session.selectedLines.formUnion(entry.diff.changeIDs.filter { range.contains($0) })
        } else if session.selectedLines.contains(line.id) {
            session.selectedLines.remove(line.id)
        } else {
            session.selectedLines.insert(line.id)
        }
        anchor = (entry.id, line.id)
    }
}
