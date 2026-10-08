import Foundation

extension Sequence {
    func uniqued<ID: Hashable>(on id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        return filter { element in
            seen.insert(id(element)).inserted
        }
    }
}
