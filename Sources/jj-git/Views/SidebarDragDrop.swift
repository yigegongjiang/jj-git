import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Equatable {
    case repository(String)
    case group(UUID)

    var payload: String {
        switch self {
        case let .repository(path): "repository:\(path)"
        case let .group(id): "group:\(id.uuidString)"
        }
    }
}

enum SidebarDropTarget: Equatable {
    case repository(String, after: Bool)
    case group(UUID, after: Bool)
    case intoGroup(UUID?)

    var after: Bool {
        switch self {
        case let .repository(_, after), let .group(_, after): after
        case .intoGroup: false
        }
    }
}

struct SidebarDropModifier: ViewModifier {
    static let type = UTType(exportedAs: "com.yigegongjiang.jj-git.sidebar-item", conformingTo: .data)
    let destination: SidebarDropTarget
    @Binding var draggedItem: SidebarItem?
    @Binding var target: SidebarDropTarget?
    let token: String
    let workspace: Workspace
    @State private var height: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, value in height = value }
            })
            .background(isGroupTarget ? Theme.accent.opacity(0.2) : .clear)
            .overlay(alignment: target?.after == true ? .bottom : .top) {
                if isInsertionTarget {
                    Theme.accent.frame(height: 2).allowsHitTesting(false)
                }
            }
            .onDrop(of: [Self.type], delegate: SidebarDropDelegate(
                destination: destination, height: height, draggedItem: $draggedItem,
                target: $target, token: token, workspace: workspace
            ))
    }

    private var isGroupTarget: Bool {
        guard case let .intoGroup(id) = target else { return false }
        switch destination {
        case let .group(groupID, _): return id == groupID
        case let .intoGroup(groupID): return id == groupID
        case .repository: return false
        }
    }

    private var isInsertionTarget: Bool {
        switch (destination, target) {
        case let (.repository(path, _), .repository(targetPath, _)): path == targetPath
        case let (.group(id, _), .group(targetID, _)): id == targetID
        default: false
        }
    }
}

private struct SidebarDropDelegate: DropDelegate {
    static let type = SidebarDropModifier.type
    let destination: SidebarDropTarget
    let height: CGFloat
    @Binding var draggedItem: SidebarItem?
    @Binding var target: SidebarDropTarget?
    let token: String
    let workspace: Workspace

    func validateDrop(info: DropInfo) -> Bool {
        proposedTarget(info) != nil && info.hasItemsConforming(to: [Self.type])
    }

    func dropEntered(info: DropInfo) {
        target = proposedTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = proposedTarget(info)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info _: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let destination = proposedTarget(info), let item = draggedItem,
              let provider = info.itemProviders(for: [Self.type]).first else { return false }
        target = nil
        draggedItem = nil
        // 校验本窗口令牌与完整载荷，拒绝外部或其他窗口的拖入。
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { data, _ in
            guard data == Data("\(token)\n\(item.payload)".utf8) else { return }
            Task { @MainActor in
                switch (item, destination) {
                case let (.repository(path), .repository(other, after)):
                    workspace.reorderRepository(path, relativeTo: other, after: after)
                case let (.repository(path), .intoGroup(id)):
                    workspace.move(path, to: id)
                case let (.group(id), .group(other, after)):
                    workspace.reorderGroup(id, relativeTo: other, after: after)
                default: break
                }
            }
        }
        return true
    }

    private func proposedTarget(_ info: DropInfo) -> SidebarDropTarget? {
        switch (draggedItem, destination) {
        case let (.repository(path), .repository(other, _)) where path != other:
            return .repository(other, after: info.location.y > height / 2)
        case let (.repository, .group(id, _)):
            return .intoGroup(id)
        case let (.repository, .intoGroup(id)):
            return .intoGroup(id)
        case let (.group(id), .group(other, _)) where id != other:
            return .group(other, after: info.location.y > height / 2)
        default: return nil
        }
    }
}
