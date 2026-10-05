import Foundation

extension Workspace {
    @discardableResult
    func addGroup(_ name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = RepositoryGroup(name: trimmed)
        library.groups.append(group)
        save()
        return group.id
    }

    func renameGroup(_ groupID: UUID, name: String) {
        guard let index = library.groups.firstIndex(where: { $0.id == groupID }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func deleteGroup(_ groupID: UUID) {
        library.groups.removeAll { $0.id == groupID }
        for index in library.repositories.indices where library.repositories[index].groupID == groupID {
            library.repositories[index].groupID = nil
        }
        save()
    }

    func move(_ path: String, to groupID: UUID?) {
        guard let index = library.repositories.firstIndex(where: { $0.path == path }) else { return }
        library.repositories[index].groupID = groupID
        save()
    }

    func setRepositoryColor(_ path: String, color: String?) {
        guard let index = library.repositories.firstIndex(where: { $0.path == path }),
              library.repositories[index].color != color else { return }
        library.repositories[index].color = color
        save()
    }
}
