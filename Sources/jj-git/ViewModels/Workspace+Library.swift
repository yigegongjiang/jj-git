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

    var orderedGroups: [RepositoryGroup] {
        library.sidebarOrderCustomized ? library.groups : library.groups.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func orderedRepositories(in groupID: UUID?) -> [SavedRepository] {
        let items = library.repositories.filter { $0.groupID == groupID }
        return library.sidebarOrderCustomized ? items : items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func customizeSidebarOrder() {
        guard !library.sidebarOrderCustomized else { return }
        library.groups = orderedGroups
        library.repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        library.sidebarOrderCustomized = true
    }

    func sortSidebarByName() {
        library.sidebarOrderCustomized = false
        save()
    }

    func reorderGroup(_ groupID: UUID, relativeTo targetID: UUID, after: Bool) {
        guard groupID != targetID,
              library.groups.contains(where: { $0.id == groupID }),
              library.groups.contains(where: { $0.id == targetID }) else { return }
        customizeSidebarOrder()
        guard let source = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = library.groups.remove(at: source)
        guard let target = library.groups.firstIndex(where: { $0.id == targetID }) else { return }
        library.groups.insert(group, at: target + (after ? 1 : 0))
        save()
    }

    func reorderRepository(_ path: String, relativeTo targetPath: String, after: Bool) {
        guard path != targetPath,
              library.repositories.contains(where: { $0.path == path }),
              let destination = library.repositories.first(where: { $0.path == targetPath }) else { return }
        customizeSidebarOrder()
        guard let source = library.repositories.firstIndex(where: { $0.path == path }) else { return }
        var repository = library.repositories.remove(at: source)
        repository.groupID = destination.groupID
        guard let target = library.repositories.firstIndex(where: { $0.path == targetPath }) else { return }
        library.repositories.insert(repository, at: target + (after ? 1 : 0))
        save()
    }

    func move(_ path: String, to groupID: UUID?) {
        guard groupID == nil || library.groups.contains(where: { $0.id == groupID }),
              let index = library.repositories.firstIndex(where: { $0.path == path }),
              library.repositories[index].groupID != groupID else { return }
        if library.sidebarOrderCustomized {
            var repository = library.repositories.remove(at: index)
            repository.groupID = groupID
            library.repositories.append(repository)
        } else {
            library.repositories[index].groupID = groupID
        }
        save()
    }

    func setRepositoryColor(_ path: String, color: String?) {
        guard let index = library.repositories.firstIndex(where: { $0.path == path }),
              library.repositories[index].color != color else { return }
        library.repositories[index].color = color
        save()
    }
}
