import SwiftUI

struct HistoryView: View {
    @Bindable var session: RepositorySession
    @Binding var dialog: RepositoryDialog?

    var body: some View {
        SplitPane(name: "history.graph", vertical: true, pinned: .second, initial: 330, minimum: (120, 160)) {
            CommitGraphPanel(session: session, dialog: $dialog)
        } second: {
            SplitPane(name: "history.detail", initial: 300, minimum: (200, 290)) {
                detailPanel
            } second: {
                DiffView(session: session, editable: false)
            }
        }
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let detail = session.commitDetail {
                SplitPane(name: "history.message", vertical: true, initial: 110, minimum: (40, 80)) {
                    ScrollView {
                        Text(detail.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                } second: {
                    VStack(spacing: 0) {
                        SectionHeading(title: "变更文件 · \(detail.files.count)") { EmptyView() }
                        List(selection: Binding(get: { session.selectedCommitFile?.id }, set: { path in
                            session.selectCommitFile(detail.files.first { $0.id == path })
                        })) {
                            ForEach(detail.files) { file in
                                HStack(spacing: 6) {
                                    Text(file.status).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                }.tag(file.id).help(file.path)
                            }
                        }.listStyle(.plain)
                    }
                }
            } else {
                EmptyState(title: "选择提交查看详情", symbol: "clock")
            }
        }
    }
}

private struct CommitGraphPanel: View {
    @Bindable var session: RepositorySession
    @Binding var dialog: RepositoryDialog?
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeading(title: "提交历史 · \(session.graph.count)") {
                if session.hasMoreHistory {
                    Button("加载更多") {
                        session.historyLimit += AppConfig.current.history.pageSize
                        session.refresh(forceHistory: true)
                    }.buttonStyle(.borderless).font(.caption).disabled(session.refreshing)
                }
            }
            if session.graph.isEmpty {
                EmptyState(title: "暂无提交", symbol: "clock")
            } else {
                List(selection: $selection) {
                    ForEach(session.graph) { row in
                        historyRow(row).tag(row.id)
                            .contextMenu {
                                Button("复制 SHA") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.commit.hash, forType: .string)
                                }
                                Button("从此提交新建分支…") { dialog = .branch(start: row.commit.hash) }
                                Button("在此提交新建标签…") { dialog = .tag(target: row.commit.hash) }
                            }
                    }.listRowSeparator(.hidden).listRowInsets(EdgeInsets(
                        top: 0,
                        leading: 5,
                        bottom: 0,
                        trailing: 8
                    ))
                }.listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 26)
                    .task(id: selection) {
                        await Task.yield()
                        guard !Task.isCancelled, let selection,
                              session.selectedCommit?.id != selection else { return }
                        session.selectCommit(session.graph.first { $0.id == selection }?.commit)
                    }
                    .task {
                        await Task.yield()
                        selection = session.selectedCommit?.id
                    }
            }
        }
    }

    private func historyRow(_ row: CommitGraphRow) -> some View {
        HStack(spacing: 7) {
            GraphLaneView(row: row).frame(width: CGFloat(session.graphLanes) * 12 + 12, height: 26).clipped()
            if !row.commit.decorations.isEmpty {
                Text(row.commit.decorations).font(.system(size: 10, weight: .medium))
                    .lineLimit(1).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: 190, alignment: .leading)
            }
            Text(row.commit.subject).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text(row.commit.author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 90)
            Text(row.commit.date.formatted(date: .numeric, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
            Text(row.commit.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }.frame(height: 26).help(row.commit.subject + "\n" + row.commit.author + " · " + row.commit.date.formatted())
    }
}

private struct GraphLaneView: View {
    let row: CommitGraphRow
    private let colors: [Color] = [.teal, .orange, .purple, .blue, .pink, .green]

    var body: some View {
        Canvas { context, size in
            func position(_ lane: Int) -> CGFloat {
                CGFloat(lane) * 12 + 8
            }
            for edge in row.edges {
                var path = Path()
                path.move(to: CGPoint(x: position(edge.from), y: edge.beginsAtCommit ? size.height / 2 : 0))
                path.addCurve(to: CGPoint(x: position(edge.target), y: size.height),
                              control1: CGPoint(x: position(edge.from), y: size.height * 0.7),
                              control2: CGPoint(x: position(edge.target), y: size.height * 0.7))
                context.stroke(path, with: .color(colors[edge.from % colors.count]), lineWidth: 1.5)
            }
            let center = CGPoint(x: position(row.lane), y: size.height / 2)
            if row.continuesFromAbove {
                var path = Path()
                path.move(to: CGPoint(x: center.x, y: 0))
                path.addLine(to: center)
                context.stroke(path, with: .color(colors[row.lane % colors.count]), lineWidth: 1.5)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                         with: .color(colors[row.lane % colors.count]))
        }.accessibilityLabel("提交图，轨道 \(row.lane + 1)，\(row.commit.parents.count) 个父提交")
    }
}
