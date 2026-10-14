import SwiftUI

/// 状态栏单独观察操作进度 / 提示：Git 进度行高频更新时只重绘状态栏，不重算整个仓库视图。
struct StatusBar: View {
    let session: RepositorySession
    @State private var showOperationOutput = false

    var body: some View {
        HStack(spacing: 7) {
            if let operation = session.operation {
                operationStatus(operation)
            } else if !session.notice.isEmpty {
                Label(session.notice, systemImage: "checkmark.circle").lineLimit(1).fixedSize()
                    .accessibilityIdentifier("status.notice")
                if let summary = session.operationOutput.split(whereSeparator: \.isNewline).first {
                    Button { showOperationOutput.toggle() } label: {
                        Text(summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("查看完整输出").accessibilityIdentifier("status.output")
                    .popover(isPresented: $showOperationOutput) {
                        ScrollView { Text(session.operationOutput).textSelection(.enabled).padding(12) }
                            .scrollerGutter().themed()
                            .frame(width: 520, height: 220)
                    }
                }
            } else {
                Text(session.location.root).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            RefreshIndicator(session: session)
        }.font(.ui(-1)).padding(.horizontal, 10).frame(height: 26)
    }

    /// 操作名 + Git 最新输出（阶段 / 百分比 / 速率）+ 已用时间；有百分比时显示确定进度条。
    private func operationStatus(_ operation: String) -> some View {
        let line = session.operationProgress
        let percent = line.flatMap(Self.percent)
        return Group {
            if let percent {
                ProgressView(value: percent, total: 100).progressViewStyle(.linear).frame(width: 80)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(line.map { operation + " · " + $0 } ?? operation + "…")
                .lineLimit(1).truncationMode(.middle).monospacedDigit().help(line ?? operation)
            if let started = session.operationStarted {
                Text(timerInterval: started ... .distantFuture, countsDown: false)
                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            Button("取消") { session.cancelOperation() }.buttonStyle(.borderless)
                .accessibilityIdentifier("status.cancel")
        }.accessibilityIdentifier("status.operation")
    }

    /// `Writing objects:  45% (9/20)` 中最后一个百分比。
    /// `, done.` = 该阶段已结束、下一阶段尚无输出，显示不确定进度而非满格。
    private static func percent(_ line: String) -> Double? {
        guard !line.hasSuffix("done."), let match = line.matches(of: /(\d{1,3})%/).last,
              let value = Double(match.1), value <= 100 else { return nil }
        return value
    }
}

/// 刷新状态与变更数单独观察：每次刷新的开始 / 结束只重绘这一小块，不重算整个仓库视图。
private struct RefreshIndicator: View {
    let session: RepositorySession

    var body: some View {
        if session.refreshing {
            ProgressView().controlSize(.mini)
        }
        Text("\(session.status.changes.count) 个变更").foregroundStyle(.secondary)
            .accessibilityIdentifier("status.changes")
    }
}
