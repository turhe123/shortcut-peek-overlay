import SwiftUI
import AppKit

/// The overlay's content: header, hold-mode columns or search list, and a footer hint.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(model.mode == .hold ? "Release ⌘ Command to close"
                                     : "↑↓ select · ↩ run · ⎋ close · ★ pin favorites")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = model.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
            Text(model.appName).font(.title2.weight(.semibold)).lineLimit(1)
            if model.mode == .search {
                TextField("Search menu items", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { model.performSelected() }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.escape) { model.onClose?(); return .handled }
                    .onChange(of: model.showToken, initial: true) { searchFocused = true }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .noPermission:
            VStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.secondary)
                Text("Accessibility access needed").font(.headline)
                Text("ShortcutPeekOverlay reads menu shortcuts and detects the Command hold through the Accessibility API. Grant access in System Settings › Privacy & Security › Accessibility.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                Button("Grant Access…") { Prefs.requestAccessibility() }.buttonStyle(.borderedProminent)
            }.padding()
        case .loading:
            ProgressView("Reading menus…").padding()
        case .loaded(let snap):
            VStack(spacing: 0) {
                if model.mode == .hold { holdColumns } else { searchList }
                notes(for: snap)
            }
        }
    }

    @ViewBuilder private func notes(for snap: MenuSnapshot) -> some View {
        if snap.partial {
            Text("Reading this app's menus took too long — showing partial results.")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        } else if snap.entries.count < 3 {
            Text("This app exposes little of its menus through Accessibility, so some shortcuts may be missing.")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
    }

    @ViewBuilder private var holdColumns: some View {
        let columns = model.columnLayout
        if columns.isEmpty {
            emptyState("This app has no menu shortcuts.")
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(columns.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(columns[i]) { group in groupView(group) }
                        }.frame(width: 280, alignment: .topLeading)
                    }
                }.padding(16)
            }
        }
    }

    private func groupView(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.name).font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            ForEach(group.entries) { e in
                HStack {
                    Text(e.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Keycaps(tokens: e.keys)
                }
                .font(.system(size: 13))
                .opacity(e.enabled ? 1 : 0.4)
            }
        }
    }

    @ViewBuilder private var searchList: some View {
        let results = model.searchResults
        if results.isEmpty {
            emptyState(model.query.isEmpty ? "This app has no menu shortcuts." : "No matching menu items.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, e in
                            searchRow(e, selected: index == model.selection).id(index)
                                .onTapGesture { model.selection = index; model.performSelected() }
                        }
                    }.padding(8)
                }
                .onChange(of: model.selection) { _, new in proxy.scrollTo(new) }
            }
        }
    }

    private func searchRow(_ e: MenuEntry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.toggleFavorite(e) } label: {
                Image(systemName: model.isFavorite(e) ? "star.fill" : "star")
                    .foregroundStyle(model.isFavorite(e) ? Color.yellow : Color.secondary)
            }.buttonStyle(.plain).help("Pin to top")
            Text(e.title).lineLimit(1)
            Text(e.menu).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Keycaps(tokens: e.keys)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
        .opacity(e.enabled ? 1 : 0.45)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.secondary).padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders shortcut tokens (⌘, ⇧, K, F5…) as small keycaps.
struct Keycaps: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
                Text(t)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .frame(minWidth: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.2)))
            }
        }
    }
}

/// Translucent HUD-style blur behind the overlay.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
