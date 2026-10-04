import Foundation

extension Workspace {
    func restore() async {
        let selected = library.selectedPath
        for path in library.tabs {
            await open(path, select: path == selected)
        }
        // 打开失败的标签保留（可能只是等待系统授权），点击标签时重试；不再需要时手动关闭。
        if self.selected == nil, let path = library.tabs.first(where: { sessions[$0] != nil }) {
            select(path)
        }
    }
}
