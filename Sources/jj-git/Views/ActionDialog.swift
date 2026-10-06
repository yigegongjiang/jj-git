import SwiftUI

enum RepositoryDialog: Identifiable {
    case branch(start: String)
    case renameBranch(GitReference)
    case deleteBranch(GitReference)
    case tag(target: String)
    case deleteTag(GitReference)
    case pushTag(GitReference)
    case remote(GitRemote?)
    case push(force: Bool)

    var id: String {
        title
    }

    var title: String {
        switch self {
        case .branch: "新建并检出分支"
        case .renameBranch: "重命名分支"
        case let .deleteBranch(reference): reference.remote ? "删除远端分支" : "删除本地分支"
        case .tag: "新建标签"
        case .deleteTag: "删除标签"
        case .pushTag: "推送标签"
        case let .remote(remote): remote == nil ? "添加远程" : "编辑远程"
        case let .push(force): force ? "强制推送（force-with-lease）" : "Push"
        }
    }
}

struct ActionDialog: View {
    let dialog: RepositoryDialog
    let session: RepositorySession
    @State private var name = ""
    @State private var value = ""
    @State private var message = ""
    @State private var remote = ""
    @State private var force = false
    @State private var deleteRemote = false
    @State private var pushTag = false
    @State private var lease: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialog.title).font(.ui(1, weight: .semibold))
            Form { fields }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认", action: submit).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear(perform: initialize)
        .onChange(of: remote) { _, _ in updateLease() }
        .onChange(of: name) { _, _ in updateLease() }
    }

    @ViewBuilder private var fields: some View {
        switch dialog {
        case .branch:
            TextField("分支名称", text: $name)
            TextField("起点", text: $value)
        case .renameBranch:
            TextField("新名称", text: $name)
        case let .deleteBranch(reference):
            Text(reference.name).font(.mono())
            if reference.remote {
                Text("将删除远端分支；远端提交已变化时会拒绝删除。")
                    .foregroundStyle(Theme.orange)
            } else {
                Toggle("允许删除尚未合并的分支", isOn: $force)
                if !reference.upstream.isEmpty {
                    Toggle("同时删除上游 \(reference.upstream)", isOn: $deleteRemote)
                }
            }
        case .tag:
            TextField("标签名称", text: $name)
            TextField("目标提交", text: $value)
            TextField("说明（留空使用标签名）", text: $message)
            if !session.remotes.isEmpty {
                Toggle("创建后推送到远程", isOn: $pushTag)
                if pushTag {
                    remotePicker
                }
            }
        case let .deleteTag(reference):
            Text("删除标签 \(reference.name)？")
            if !session.remotes.isEmpty {
                Toggle("同时从所有远程删除此标签", isOn: $deleteRemote)
            }
        case let .pushTag(reference):
            Text(reference.name)
            remotePicker
        case .remote:
            TextField("名称", text: $name)
            TextField("URL / 本地路径", text: $value)
        case let .push(force):
            remotePicker
            TextField("远端分支", text: $name)
            if force {
                Text("将用当前 HEAD 改写远端分支；远端发生新变化时 Git 会拒绝操作。")
                    .foregroundStyle(Theme.orange)
                Text(lease.map { "已知远端提交：\($0.prefix(12))" } ?? "缺少已知远端提交，请先 Fetch。")
                    .font(.ui(-2)).textSelection(.enabled)
            }
        }
    }

    private var remotePicker: some View {
        Picker("远程", selection: $remote) {
            ForEach(session.remotes) { Text($0.name).tag($0.name) }
        }
    }

    private var valid: Bool {
        switch dialog {
        case .branch, .tag, .remote: !name.isEmpty && !value.isEmpty
        case .renameBranch: !name.isEmpty
        case .deleteBranch, .deleteTag: true
        case .pushTag: !remote.isEmpty
        case let .push(force): !remote.isEmpty && !name.isEmpty && (!force || lease != nil)
        }
    }

    private func initialize() {
        remote = session.defaultRemote
        switch dialog {
        case let .branch(start): value = start
        case let .renameBranch(reference): name = reference.name
        case let .tag(target):
            value = target
            pushTag = !session.remotes.isEmpty
        case let .remote(existing):
            name = existing?.name ?? "origin"
            value = existing?.url ?? ""
        case .push: name = PushDestination(session: session).branch
        default: break
        }
        updateLease()
    }

    private func updateLease() {
        lease = session.references.first { $0.fullName == "refs/remotes/\(remote)/\(name)" }?.target
    }

    private func submit() {
        let action: RepositoryAction
        switch dialog {
        case .branch: action = .createBranch(name, start: value)
        case let .renameBranch(reference): action = .renameBranch(reference.name, name)
        case let .deleteBranch(reference):
            action = branchDeletion(reference)
        case .tag: action = .createTag(name, target: value, message: message)
        case let .deleteTag(reference):
            action = .deleteTag(reference.name, remotes: deleteRemote ? session.remotes.map(\.name) : [])
        case let .pushTag(reference): action = .pushTag(reference.name, remote: remote)
        case let .remote(existing):
            action = existing.map { .editRemote($0.name, url: value, newName: name) } ?? .addRemote(name, url: value)
        case let .push(force): action = .push(remote: remote, branch: name, lease: force ? lease : nil)
        }
        let followUp = followUpAction()
        session.perform(action, title: dialog.title) {
            if let followUp {
                session.perform(followUp.action, title: followUp.title)
            }
        }
        dismiss()
    }

    /// 主操作成功后的连带操作：推送新标签 / 删除上游分支。
    private func followUpAction() -> (action: RepositoryAction, title: String)? {
        switch dialog {
        case .tag where pushTag && !remote.isEmpty:
            return (.pushTag(name, remote: remote), "推送标签")
        case let .deleteBranch(reference) where deleteRemote && !reference.remote:
            guard let upstream = session.references.first(where: { $0.remote && $0.name == reference.upstream }),
                  let remote = remoteName(for: upstream) else { return nil }
            return (.deleteRemoteBranch(upstream, remote: remote), "删除上游分支")
        default:
            return nil
        }
    }

    private func branchDeletion(_ reference: GitReference) -> RepositoryAction {
        reference.remote ? .deleteRemoteBranch(reference, remote: remoteName(for: reference) ?? "")
            : .deleteBranch(reference.name, force: force)
    }

    private func remoteName(for reference: GitReference) -> String? {
        session.remotes.sorted { $0.name.count > $1.name.count }
            .first { reference.name.hasPrefix($0.name + "/") }?.name
    }
}

struct PushDestination {
    let remote: String
    let branch: String
    let lease: String?

    var label: String {
        "\(remote)/\(branch)"
    }

    @MainActor
    init(session: RepositorySession) {
        remote = session.defaultRemote
        branch = session.status.upstream.hasPrefix(remote + "/")
            ? String(session.status.upstream.dropFirst(remote.count + 1)) : session.status.branch
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        lease = session.references.first { $0.fullName == remoteRef }?.target
    }
}
