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

        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func saveQuickNote(title: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return }

        let note = QuickNote(context: container.viewContext)
        note.id = UUID()
        note.title = trimmedTitle.isEmpty ? "Untitled note" : trimmedTitle
        note.body = trimmedBody
        note.createdAt = Date()

        save()
    }

    func delete(_ note: QuickNote) {
        container.viewContext.delete(note)
        save()
    }

    func fetchRecentNotes(limit: Int = 20) -> [QuickNote] {
        let request = QuickNote.recentRequest(limit: limit)
        return (try? container.viewContext.fetch(request)) ?? []
    }

    private func save() {
        guard container.viewContext.hasChanges else { return }
        try? container.viewContext.save()
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
