import CoreData
import Foundation

@MainActor
final class PersistenceController {
    /// Under XCTest the shared store is in memory, so tests never touch the user's notes.
    static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let shared = PersistenceController(inMemory: isRunningUnitTests)
    /// One model instance per process; Core Data cannot map `QuickNote` when several models define it.
    private static let model = makeModel()

    let container: NSPersistentContainer
    /// Set if the store could not be opened; saves then fail and report it.
    private(set) var loadError: Error?

    init(inMemory: Bool = false) {
        let model = Self.model
        container = NSPersistentContainer(name: "Launcher", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let storeURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.subset.launcher", isDirectory: true)
                .appendingPathComponent("QuickNotes.sqlite")
            try? FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        }

        var storeLoadError: Error?
        container.loadPersistentStores { _, error in
            if let error {
                storeLoadError = error
                NSLog("Launcher: Quick Notes store failed to load: %@", error.localizedDescription)
            }
        }
        loadError = storeLoadError

        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    nonisolated static func isBlankNote(title: String, body: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saves a note. A blank note is ignored and reported as success; a store failure is
    /// rolled back and returned so the caller can keep the user's draft.
    @discardableResult
    func saveQuickNote(title: String, body: String) -> Result<Void, Error> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isBlankNote(title: trimmedTitle, body: trimmedBody) else { return .success(()) }
        if let loadError { return .failure(loadError) }

        let note = QuickNote(context: container.viewContext)
        note.id = UUID()
        note.title = trimmedTitle.isEmpty ? "Untitled note" : trimmedTitle
        note.body = trimmedBody
        note.createdAt = Date()

        return save()
    }

    @discardableResult
    func delete(_ note: QuickNote) -> Result<Void, Error> {
        container.viewContext.delete(note)
        return save()
    }

    func fetchRecentNotes(limit: Int = 20) -> [QuickNote] {
        let request = QuickNote.recentRequest(limit: limit)
        return (try? container.viewContext.fetch(request)) ?? []
    }

    private func save() -> Result<Void, Error> {
        guard container.viewContext.hasChanges else { return .success(()) }
        do {
            try container.viewContext.save()
            return .success(())
        } catch {
            container.viewContext.rollback()
            NSLog("Launcher: Quick Notes save failed: %@", error.localizedDescription)
            return .failure(error)
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "QuickNote"
        entity.managedObjectClassName = NSStringFromClass(QuickNote.self)

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false

        let body = NSAttributeDescription()
        body.name = "body"
        body.attributeType = .stringAttributeType
        body.isOptional = false

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = true

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false

        entity.properties = [id, title, body, createdAt]
        model.entities = [entity]
        return model
    }
}
