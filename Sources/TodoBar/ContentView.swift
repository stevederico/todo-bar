import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: TodoBarModel
    /// Must observe store directly — nested `model.store` alone does not refresh SwiftUI.
    @ObservedObject var store: TodoStore
    @State private var query = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var newTodoText = ""
    @State private var showAddField = false
    @State private var showCompleted = false
    @FocusState private var newTodoFocused: Bool

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var completedCount: Int {
        store.sections.reduce(0) { $0 + $1.items.filter(\.isCompleted).count }
    }

    private var filtered: [TodoSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.sections.compactMap { section in
            var items = section.items.filter { showCompleted || !$0.isCompleted }
            if !q.isEmpty {
                items = items.filter {
                    $0.text.localizedCaseInsensitiveContains(q)
                        || section.title.localizedCaseInsensitiveContains(q)
                }
            }
            guard !items.isEmpty else { return nil }
            return TodoSection(id: section.id, title: section.title, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if showAddField {
                addField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else if let status = store.lastStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 580)
        .onAppear { store.syncFromRemote() }
        .sheet(item: $renameID) { id in
            RenameSheet(
                title: renameText,
                onCancel: { renameID = nil },
                onSave: { name in
                    model.renameSource(id, title: name)
                    renameID = nil
                }
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.sources) { source in
                        tabChip(source)
                    }
                }
            }

            Text("\(store.itemCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Button {
                model.pickAndAddSource()
            } label: {
                Text("Add List")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Add Another Todo File")

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAddField.toggle()
                }
                if showAddField {
                    DispatchQueue.main.async { newTodoFocused = true }
                } else {
                    newTodoText = ""
                    newTodoFocused = false
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(
                        showAddField ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                showAddField ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.15),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(showAddField ? "Hide New To-Do" : "Add To-Do")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("New To-Do", text: $newTodoText)
                .textFieldStyle(.plain)
                .focused($newTodoFocused)
                .onSubmit { submitNewTodo() }
            if !newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") { submitNewTodo() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAddField = false
                    newTodoText = ""
                    newTodoFocused = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabChip(_ source: TodoSource) -> some View {
        let selected = source.id == model.selectedID
        return Button {
            query = ""
            model.select(source.id)
        } label: {
            Text(source.title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                renameText = source.title
                renameID = source.id
            }
            Button("Reveal In Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([source.url])
            }
            if model.sources.count > 1 {
                Divider()
                Button("Remove Tab", role: .destructive) {
                    model.removeSource(source.id)
                }
            }
        }
        .help(source.path)
    }

    /// ScrollView (not List) — List+onMove steals checkbox taps on macOS.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { section in
                    let openItems = section.items.filter { !$0.isCompleted }
                    let doneItems = section.items.filter(\.isCompleted)

                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(Array(openItems.enumerated()), id: \.element.id) { index, item in
                        TodoRow(
                            item: item,
                            canMoveUp: index > 0 && !isFiltering,
                            canMoveDown: index < openItems.count - 1 && !isFiltering,
                            onComplete: { store.complete(item) },
                            onSave: { store.updateItem(item, text: $0) },
                            onDelete: { store.deleteItem(item) },
                            onMoveUp: { store.moveOpenItem(item, direction: -1) },
                            onMoveDown: { store.moveOpenItem(item, direction: 1) }
                        )
                        .padding(.horizontal, 8)
                    }

                    if showCompleted {
                        ForEach(doneItems) { item in
                            TodoRow(
                                item: item,
                                canMoveUp: false,
                                canMoveDown: false,
                                onComplete: { store.complete(item) },
                                onSave: { store.updateItem(item, text: $0) },
                                onDelete: { store.deleteItem(item) },
                                onMoveUp: {},
                                onMoveDown: {}
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                }

                if filtered.isEmpty {
                    Text(isFiltering ? "No matches" : "No open todos in this file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 12)
        }
        .id(model.selectedID)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button("Refresh") { store.syncFromRemote() }
                Button("Open File") { store.openInEditor() }
                Button("Reveal") { store.revealInFinder() }
                if completedCount > 0 {
                    Button(showCompleted ? "Hide Completed" : "Show Completed (\(completedCount))") {
                        showCompleted.toggle()
                    }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Text(store.filePath.path)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
    }

    private func submitNewTodo() {
        let text = newTodoText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newTodoText = ""
        store.addItem(text: text)
        newTodoFocused = true
    }
}

// MARK: - Rename

private struct RenameSheet: View {
    @State var title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tab")
                .font(.headline)
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave(title) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(title) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

private struct TodoRow: View {
    let item: TodoItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onComplete: () -> Void
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Large hit target; plain button + high-priority tap (MenuBarExtra is flaky).
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(item.isCompleted ? Color.accentColor : .secondary)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
                .onTapGesture { onComplete() }
                .help(item.isCompleted ? "Reopen" : "Mark Complete")

            if editing {
                TextField("To-Do", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEdit() }
                    .onTapGesture(count: 1) {
                        withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                    }
                    .help(expanded ? "Double-Click To Edit" : "Click To Expand · Double-Click To Edit")
            }

            if !item.isCompleted {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .opacity(canMoveUp ? 0.6 : 0.15)
                        .onTapGesture { if canMoveUp { onMoveUp() } }
                        .help("Move Up")

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .opacity(canMoveDown ? 0.6 : 0.15)
                        .onTapGesture { if canMoveDown { onMoveDown() } }
                        .help("Move Down")
                }
            }
        }
        .padding(.leading, CGFloat(min(item.indent, 8)) * 4)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 6))
        .opacity(item.isCompleted ? 0.75 : 1)
        .contextMenu {
            Button(item.isCompleted ? "Reopen" : "Mark Complete") { onComplete() }
            if !item.isCompleted {
                Button("Move Up") { onMoveUp() }
                    .disabled(!canMoveUp)
                Button("Move Down") { onMoveDown() }
                    .disabled(!canMoveDown)
            }
            Button("Edit…") { beginEdit() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .onChange(of: item.text) { _ in
            if editing { cancelEdit() }
            expanded = false
        }
    }

    private func beginEdit() {
        draft = item.text
        editing = true
        expanded = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitEdit() {
        let value = draft
        editing = false
        fieldFocused = false
        onSave(value)
    }

    private func cancelEdit() {
        editing = false
        fieldFocused = false
        draft = item.text
    }
}
