import SwiftUI

/// 顶部「性能」面板：打开或点「重新测量」时测量一次，不持续采样。
/// 口径与面板未打开时一致：内存取弹窗出现前的采样；CPU 窗口避开弹窗动画与激活刷新，窗口内不更新界面。
struct PerformanceView: View {
    let workspace: Workspace
    let baseline: ProcessSample?
    @State private var sample: ProcessSample?
    @State private var cpu: Double?
    @State private var tabs: [TabUsage] = []
    @State private var measuring = false
    @State private var request = 0
    @State private var measuredAt: Date?
    @Environment(\.dismiss) private var dismiss

    private struct TabUsage: Identifiable {
        let path: String
        let selected: Bool
        let usage: SessionUsage?
        var id: String {
            path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                metric("CPU", cpu.map(Self.percent) ?? "—",
                       help: "本进程占用，单核满载 100%，多核可超过；不含 Git 子进程")
                metric("内存", sample.map { Self.bytes($0.footprint) } ?? "—", help: "与活动监视器「内存」一致")
                metric("内存峰值", sample.map { Self.bytes($0.peakFootprint) } ?? "—", help: "启动以来的最大内存")
                metric("常驻内存", sample.map { Self.bytes($0.resident) } ?? "—", help: "当前驻留物理内存的页面 (RSS)")
                metric("线程", sample.map { "\($0.threads)" } ?? "—", help: "本进程线程数")
                metric("累计 CPU 时间", sample.map { Self.duration($0.cpuSeconds) } ?? "—", help: "启动以来本进程 CPU 时间")
                metric("Git 累计 CPU 时间", sample.map { Self.duration($0.childCPUSeconds) } ?? "—",
                       help: "启动以来已结束的 Git 命令 CPU 时间合计")
            }
            ThemedDivider()
            Text("标签内存（估算）").font(.ui(0, weight: .semibold))
                .help("标签持有的状态 / 提交历史 / 差异数据；不含界面渲染与系统框架")
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(tabs) { tab in
                        GridRow {
                            Text(URL(fileURLWithPath: tab.path).lastPathComponent)
                                .fontWeight(tab.selected ? .semibold : .regular)
                                .foregroundStyle(tab.usage == nil ? Theme.badge : Theme.foreground)
                                .lineLimit(1).truncationMode(.middle).help(tab.path)
                            Text(detail(tab)).foregroundStyle(.secondary).lineLimit(1)
                            Text(tab.usage.map { Self.bytes(UInt64($0.bytes)) } ?? "—")
                                .font(.mono()).gridColumnAlignment(.trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            if let sample {
                let total = UInt64(tabs.reduce(0) { $0 + ($1.usage?.bytes ?? 0) })
                let rest = Self.bytes(sample.footprint - min(sample.footprint, total))
                Text("标签合计 \(Self.bytes(total))；其余 \(rest) 为界面 / 运行时 / 系统框架")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("重新测量") { request += 1 }.disabled(measuring)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(12).frame(width: 460).themed()
        .task(id: request) { await measure() }
    }

    private func metric(_ title: String, _ value: String, help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.mono()).textSelection(.enabled)
        }
        .help(help)
    }

    private func detail(_ tab: TabUsage) -> String {
        guard let usage = tab.usage else { return "未挂载" }
        var parts = [tab.selected ? "当前" : "后台", "提交 \(usage.commits)"]
        if usage.diffFiles > 0 {
            parts.append("差异 \(usage.diffFiles) 文件 / \(usage.diffLines) 行")
        }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if measuring {
            return "测量中…"
        }
        return measuredAt.map { "测量于 \($0.formatted(date: .omitted, time: .standard))" } ?? ""
    }

    /// CPU 需两次采样取差值；结果最后一次性写入界面，避免渲染落入测量窗口。关闭面板即取消。
    private func measure() async {
        measuring = true
        defer { measuring = false }
        // 重新测量时弹窗已显示，内存含面板自身（数 MB）。
        guard let memory = request == 0 ? baseline ?? ProcessSample.current() : ProcessSample.current() else { return }
        do {
            try await Task.sleep(for: .milliseconds(500))
            try await settle()
            guard let start = ProcessSample.current() else { return }
            try await Task.sleep(for: .seconds(1))
            guard let end = ProcessSample.current() else { return }
            let measured = await measureTabs()
            guard !Task.isCancelled else { return }
            sample = memory
            cpu = end.cpuPercent(since: start)
            tabs = measured
            measuredAt = Date()
        } catch { return }
    }

    /// 点击按钮若同时激活 App，会引发约 1~2 秒的刷新（含状态栏转圈）与重绘；
    /// 等刷新结束且连续 2 个 100ms 片段低于 5% 再开窗口，最多等 3 秒。持续占用照常测出，只排除瞬时活动。
    private func settle() async throws {
        var previous = ProcessSample.current()
        var quiet = 0
        var waited = 0
        while quiet < 2, waited < 30 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
            guard let last = previous, let now = ProcessSample.current() else { return }
            let idle = now.cpuPercent(since: last) < 5 && workspace.selected?.refreshing != true
            quiet = idle ? quiet + 1 : 0
            previous = now
        }
    }

    private func measureTabs() async -> [TabUsage] {
        let selected = workspace.library.selectedPath
        let snapshots = workspace.library.tabs.map { ($0, workspace.sessions[$0]?.snapshot) }
        let measured = await Task.detached(priority: .utility) {
            snapshots.map { ($0.0, $0.1?.usage()) }
        }.value
        // 按估算体积降序；相同时保持标签顺序。
        return measured.enumerated().sorted {
            let left = $0.element.1?.bytes ?? -1, right = $1.element.1?.bytes ?? -1
            return left != right ? left > right : $0.offset < $1.offset
        }.map { TabUsage(path: $0.element.0, selected: $0.element.0 == selected, usage: $0.element.1) }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f 秒", seconds) : String(format: "%.1f 分", seconds / 60)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
