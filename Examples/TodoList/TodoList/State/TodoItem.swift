import Foundation

@Observable
final class TodoItem: NSObject, Identifiable {
    let id = UUID()
    @objc dynamic var title: String
    @objc dynamic var isCompleted: Bool = false

    init(title: String) {
        self.title = title
        super.init()
    }

    override convenience init() {
        self.init(title: "")
    }
}
