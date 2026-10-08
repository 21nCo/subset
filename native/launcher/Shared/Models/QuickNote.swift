import CoreData
import Foundation

@objc(QuickNote)
final class QuickNote: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String?
    @NSManaged var body: String
    @NSManaged var createdAt: Date
}

extension QuickNote {
    @nonobjc
    class func fetchRequest() -> NSFetchRequest<QuickNote> {
        NSFetchRequest<QuickNote>(entityName: "QuickNote")
    }

    static func recentRequest(limit: Int = 20) -> NSFetchRequest<QuickNote> {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \QuickNote.createdAt, ascending: false)]
        request.fetchLimit = limit
        return request
    }
}
