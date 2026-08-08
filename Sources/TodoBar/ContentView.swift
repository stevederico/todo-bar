import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: TodoBarModel
    @State private var query = ""
    @State private var renameID: UUID?
    @State private var renameText = ""

    private var store: TodoStore { model.store }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [TodoSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.sections }
        return store.sections.compactMap { section in
            let items = section.items.filter {
                $0.text.localizedCaseInsensitiveContains(q)
                    || section.title.localizedCaseInsensitiveContains(q)
            }
            guard !items.isEmpty else { return nil }
            return TodoSection(id: section.id, title: section.title, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
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
        .disabled(store.isBusy)
        .overlay {
            if store.isBusy {
                ProgressView()
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
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

    /// Title, count, tabs, and + — single row.
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
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Add Todo File")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private var list: some View {
        List {
            ForEach(filtered) { section in
                Section {
                    ForEach(section.items) { item in
                        TodoRow(item: item) {
                            store.complete(item)
                        }
                    }
                    .onMove { source, dest in
                        guard !isFiltering else { return }
                        store.moveItems(in: section.title, from: source, to: dest)
                    }
                } header: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }

            if filtered.isEmpty {
                Text(isFiltering ? "No matches" : "No open todos in this file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 28)
        .id(model.selectedID) // reset list scroll/state on tab switch
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
                Button("Refresh") { store.reload() }
                Button("Open File") { store.openInEditor() }
                Button("Reveal") { store.revealInFinder() }
                Spacer()
                if !isFiltering {
                    Text("Drag To Reorder")
                        .foregroundStyle(.tertiary)
                }
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
        }
        .padding(12)
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
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark Complete (commits)")

            Text(item.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .help("Drag To Reorder")
        }
        .padding(.leading, CGFloat(min(item.indent, 8)) * 4)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Mark Complete") { onComplete() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
        }
    }
}
