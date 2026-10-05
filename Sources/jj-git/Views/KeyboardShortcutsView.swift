// swiftformat:options --commas inline
import SwiftUI

struct KeyboardShortcutsView: View {
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var sections: [ShortcutSection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.catalog.compactMap { section in
            let entries = section.entries.filter {
                term.isEmpty || "\(section.title) \($0.title) \($0.keys) \($0.detail) \($0.searchTerms)"
                    .localizedStandardContains(term)
            }
            return entries.isEmpty ? nil : ShortcutSection(title: section.title, entries: entries)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快捷键").font(.ui(2, weight: .semibold))
                Spacer()
                Text("⌘ Command · ⌥ Option · ⌃ Control · ⇧ Shift")
                    .font(.ui(-2)).foregroundStyle(.secondary)
            }
            TextField("搜索操作或快捷键", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
            ScrollView {
                if sections.isEmpty {
                    Text("没有匹配的快捷键").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title).font(.ui(weight: .semibold)).foregroundStyle(Theme.accent)
                                ForEach(section.entries, id: \.title) { entry in
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.title)
                                            if !entry.detail.isEmpty {
                                                Text(entry.detail).font(.ui(-2)).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Text(entry.keys).font(.mono()).textSelection(.enabled)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Text("仓库操作需打开仓库；不可用操作以界面状态为准。")
                    .font(.ui(-2)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 620, height: 560)
        .onAppear { searchFocused = true }
    }

    private static let catalog = [
        ShortcutSection(title: "仓库与窗口", entries: [
            Shortcut("打开仓库", "⌘O"),
            Shortcut("扫描目录", "⇧⌘O"),
            Shortcut("最近仓库", "⌘P", detail: "输入筛选，↑↓ 选择，回车打开", searchTerms: "recent quick open"),
            Shortcut("全部仓库", "⇧⌘P", detail: "搜索侧栏全部仓库的名称或路径，↑↓ 选择，回车打开", searchTerms: "sidebar repository search"),
            Shortcut("关闭仓库标签", "⌘W", detail: "当前仓库无操作进行时"),
            Shortcut("下一个仓库标签", "⌘⌥→ / ⌃Tab", searchTerms: "right tab"),
            Shortcut("上一个仓库标签", "⌘⌥← / ⇧⌃Tab", searchTerms: "left tab"),
            Shortcut("显示 / 隐藏侧边栏", "⇧⌘S"),
            Shortcut("打开配置文件", "⌘,"),
            Shortcut("查看快捷键", "⇧⌘/", searchTerms: "help")
        ]),
        ShortcutSection(title: "视图与工具", entries: [
            Shortcut("提交历史", "⌘1"),
            Shortcut("本地变更", "⌘2"),
            Shortcut("切换提交历史 / 本地变更", "Tab", detail: "主窗口无弹窗且焦点不在可编辑文本时"),
            Shortcut("刷新", "⌘R"),
            Shortcut("在终端打开", "⇧⌘T", searchTerms: "terminal"),
            Shortcut("在编辑器打开", "⇧⌘E", searchTerms: "editor")
        ]),
        ShortcutSection(title: "变更与提交", entries: [
            Shortcut("全部暂存", "⇧⌘A", searchTerms: "stage"),
            Shortcut("暂存 / 取消暂存选中文件", "↩ / Space", detail: "焦点在变更文件列表时；也可双击", searchTerms: "return enter 空格"),
            Shortcut("提交", "⌘↩", detail: "本地变更视图，满足提交条件时", searchTerms: "commit return enter"),
            Shortcut("提交并推送", "⌘⌥↩", detail: "本地变更视图，满足提交与推送条件时", searchTerms: "commit push return enter"),
            Shortcut("新建并检出分支", "⌘B", detail: "仓库侧栏可见且已有提交时", searchTerms: "branch")
        ]),
        ShortcutSection(title: "远程同步", entries: [
            Shortcut("Fetch", "⇧⌘F"),
            Shortcut("Pull", "⌥⌘P", detail: "已配置上游时"),
            Shortcut("Push 到上游", "⇧⌘U", detail: "非 detached HEAD 且存在远程时")
        ]),
        ShortcutSection(title: "弹窗", entries: [
            Shortcut("确认 / 保存", "↩", detail: "操作满足执行条件时", searchTerms: "return enter"),
            Shortcut("取消 / 关闭", "Esc", searchTerms: "escape")
        ])
    ]
}

private struct ShortcutSection {
    let title: String
    let entries: [Shortcut]
}

private struct Shortcut {
    let title: String
    let keys: String
    let detail: String
    let searchTerms: String

    init(_ title: String, _ keys: String, detail: String = "", searchTerms: String = "") {
        self.title = title
        self.keys = keys
        self.detail = detail
        self.searchTerms = searchTerms
    }
}
