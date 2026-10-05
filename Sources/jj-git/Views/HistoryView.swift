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
                        Text(detail.message).font(.code()).textSelection(.enabled)
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
                                    Text(file.status).font(.mono(-2))
                                        .foregroundStyle(.secondary)
                                    Text(file.path).font(.ui()).lineLimit(1).truncationMode(.middle)
                                }.tag(file.id).help(file.path)
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
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
                    }.buttonStyle(.borderless).font(.ui(-2)).disabled(session.refreshing)
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
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, rowHeight)
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

    /// 图轨道与行同高，字号变化时一起缩放，避免轨道线断开。
    private var rowHeight: CGFloat {
        Typography.shared.fontSize + 14
    }

    private func historyRow(_ row: CommitGraphRow) -> some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: CGFloat(session.graphLanes) * 12 + 12, height: 0)
            Group {
                if !row.commit.decorations.isEmpty {
                    CommitRefLayout {
                        ForEach(Array(row.commit.decorations.components(separatedBy: ", ").enumerated()),
                                id: \.offset) { _, ref in
                            let isTag = ref.hasPrefix("tag: ")
                            Text(isTag ? String(ref.dropFirst(5)) : ref).font(.ui(-2, weight: .medium))
                                .foregroundStyle(isTag ? Theme.green : Theme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(isTag ? Theme.green.opacity(0.25) : Theme.badge,
                                            in: RoundedRectangle(cornerRadius: 3))
                                .help(ref)
                        }
                    }.frame(width: 190).padding(.vertical, 3)
                }
                // List 行不继承外层字体，需显式指定。
                Text(row.commit.subject).font(.ui()).lineLimit(1)
                Spacer(minLength: 4)
                Text(row.commit.author).font(.ui(-1)).foregroundStyle(.secondary).lineLimit(1).frame(width: 90)
                Text(row.commit.date.formatted(date: .numeric, time: .shortened))
                    .font(.ui(-1)).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                Text(row.commit.shortHash).font(.mono(-2)).foregroundStyle(.secondary)
            }.opacity(row.merged ? 1 : Theme.notMergedOpacity)
        }.frame(minHeight: rowHeight)
            .overlay(alignment: .leading) {
                GraphLaneView(row: row).frame(width: CGFloat(session.graphLanes) * 12 + 12).clipped()
                    .allowsHitTesting(false)
            }
            .help(row.commit.subject + "\n" + row.commit.author + " · " + row.commit.date.formatted())
    }
}

private struct CommitRefLayout: Layout {
    private let spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 190, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(1, width)
        var frames: [CGRect] = []
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if offsetX > 0, offsetX + size.width > width {
                offsetX = 0
                offsetY += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: offsetX, y: offsetY), size: size))
            offsetX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: offsetY + lineHeight), frames)
    }
}

private struct GraphLaneView: View {
    let row: CommitGraphRow
    private let colors = Theme.graph

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
