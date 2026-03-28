import Foundation
import SwiftUI

@Observable
final class AppState: NSObject {
    @objc dynamic var __doc__: String {
        """
        AppState — TodoList app state tree.

        Single source of truth. All views bind to paths within this tree.

        ## State Tree

        todos (NSMutableArray) — list of TodoItem objects
          todos.N (TodoItem):
            .title (String)        — the todo text
            .isCompleted (Bool)    — whether the todo is done

        newTodoText (String) — text field for adding new todos

        ## Methods

        addTodo(title: String) → {"index": N}
          Creates a new TodoItem and appends it to `todos`.
          Returns the index of the new item.

        toggleTodo(index: Int)
          Toggles `isCompleted` on the todo at the given index.

        removeTodo(index: Int)
          Removes the todo at the given index.

        clearCompleted()
          Removes all completed todos.

        ## Common Workflows

        Add a todo:
          call addTodo {"title": "Buy milk"}

        Complete a todo:
          call toggleTodo {"index": 0}

        Edit a todo's title:
          set todos.0.title "Buy oat milk instead"

        Check all todos:
          get todos

        Remove completed:
          call clearCompleted
        """
    }

    @objc dynamic var todos: NSMutableArray = [] // [TodoItem]
    @objc dynamic var newTodoText: String = ""

    // Computed
    var activeTodos: [TodoItem] {
        (todos as! [TodoItem]).filter { !$0.isCompleted }
    }

    var completedTodos: [TodoItem] {
        (todos as! [TodoItem]).filter { $0.isCompleted }
    }

    var activeCount: Int { activeTodos.count }

    // MARK: - Actions

    /// Reassign `todos` to trigger @Observable change tracking.
    private func notifyTodosChanged() {
        let copy = NSMutableArray(array: todos)
        todos = copy
    }

    @objc func addTodo(title: String) -> NSDictionary? {
        let item = TodoItem(title: title)
        todos.add(item)
        notifyTodosChanged()
        return ["index": todos.count - 1]
    }

    @objc func toggleTodo(index: Int) {
        guard index >= 0 && index < todos.count else { return }
        let item = todos[index] as! TodoItem
        item.isCompleted.toggle()
        notifyTodosChanged()
    }

    @objc func removeTodo(index: Int) {
        guard index >= 0 && index < todos.count else { return }
        todos.removeObject(at: index)
        notifyTodosChanged()
    }

    @objc func clearCompleted() {
        let completed = (todos as! [TodoItem]).enumerated()
            .filter { $0.element.isCompleted }
            .map { $0.offset }
            .reversed()
        for index in completed {
            todos.removeObject(at: index)
        }
        notifyTodosChanged()
    }
}
