import BitwardenSdk
import SwiftUI

/// Reference layout (1Password iOS): Home · Items · Watchtower tabs, account button top left, + top right.
/// The one change: a Family tab, because this app is for setting up a family, not one person.
struct MainView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var tab = Tab.home
    enum Tab { case home, items, family, watchtower }

    var body: some View {
        if prefs.parentMode {
            ParentHomeView()
        } else {
            TabView(selection: $tab) {
                HomeView(tab: $tab).tag(Tab.home).tabItem { Label("Home", systemImage: "house.fill") }
                ItemsView().tag(Tab.items).tabItem { Label("Items", systemImage: "list.bullet.rectangle.portrait.fill") }
                FamilyView().tag(Tab.family).tabItem { Label("Family", systemImage: "person.3.fill") }
                WatchtowerView().tag(Tab.watchtower).tabItem { Label("Watchtower", systemImage: "shield.lefthalf.filled") }
            }
            .overlay(alignment: .top) { TravelBanner() }
        }
    }
}

struct TravelBanner: View {
    @Environment(Session.self) private var session
    var body: some View {
        if session.travelMode {
            Label("Travel Mode is on: only travel-safe items are on this iPhone", systemImage: "airplane")
                .font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.orange.opacity(0.9), in: Capsule()).foregroundStyle(.white).padding(.top, 2)
        }
    }
}

/// Toolbar shared by the tabs: account (settings) on the left, new item on the right.
struct MainToolbar: ToolbarContent {
    @Binding var showSettings: Bool
    @Binding var showNew: Bool
    @Environment(Session.self) private var session
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: { Avatar(name: session.account?.name ?? session.account?.email ?? "?", size: 32) }
                .accessibilityLabel(Text("Settings"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .accessibilityLabel(Text("New item"))
        }
    }
}

// MARK: home

struct HomeView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @Binding var tab: MainView.Tab
    @State private var showSettings = false
    @State private var showNew = false
    @State private var showScan = false
    @State private var open: String?

    private var favorites: [CipherListView] { session.items.filter { $0.favorite && $0.deletedDate == nil } }
    private var recent: [CipherListView] { session.items.filter { $0.deletedDate == nil }.sorted { $0.revisionDate > $1.revisionDate }.prefix(8).map { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let banner = session.banner {
                        Label(banner, systemImage: "exclamationmark.triangle.fill").font(.footnote).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if session.families.isEmpty {
                        PromoCard(title: String(localized: "Set up the whole family today"),
                                  text: String(localized: "Make a family, invite up to 4 people and fill their vaults for them. Most families finish in an afternoon."),
                                  symbol: "person.3.fill", color: Theme.brand) { tab = .family }
                    }
                    PromoCard(title: String(localized: "Scan a password notebook"),
                              text: String(localized: "Take a photo of a page. AZET Pass reads the sites, IDs and passwords on this iPhone and lets you check each one."),
                              symbol: "camera.viewfinder", color: Theme.warm) { showScan = true }
                    if !favorites.isEmpty { HomeSection(title: String(localized: "Favorites"), symbol: "star.fill", color: .orange, items: favorites, open: $open) }
                    HomeSection(title: String(localized: "Recently modified"), symbol: "clock.arrow.circlepath", color: .purple, items: recent, open: $open)
                    if recent.isEmpty {
                        Button { showNew = true } label: { Label("Add your first item", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .background(Theme.page)
            .navigationTitle("Home")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .refreshable { try? await session.sync() }
            .navigationDestination(item: $open) { ItemDetailView(id: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
            .sheet(isPresented: $showScan) { ScanNotebookView() }
        }
    }
}

struct PromoCard: View {
    let title: String
    let text: String
    let symbol: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.title3.bold()).multilineTextAlignment(.leading)
                Text(text).font(.subheadline).multilineTextAlignment(.leading).opacity(0.9)
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct HomeSection: View {
    let title: String
    let symbol: String
    let color: Color
    let items: [CipherListView]
    @Binding var open: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(title).font(.headline) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            ForEach(items, id: \.id) { i in
                Button { open = i.id } label: { ItemRow(item: i) }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
}

struct ItemRow: View {
    @Environment(Session.self) private var session
    let item: CipherListView
    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(name: item.name, category: ItemCategory.of(item))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.organizationId != nil {
                Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel(Text("Shared"))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: items

struct ItemsView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var showSettings = false
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    ForEach(Filter.search(query).apply(session)) { i in NavigationLink(value: i.id ?? "") { ItemRow(item: i) } }
                } else {
                    Section {
                        NavigationLink(value: Filter.all) { Label("All Items", systemImage: "tray.full.fill") }
                        NavigationLink(value: Filter.favorites) { Label("Favorites", systemImage: "star.fill") }
                    }
                    Section("Vaults") {
                        NavigationLink(value: Filter.personal) { Label("Private", systemImage: "lock.fill") }
                        ForEach(session.vaults, id: \.id) { v in
                            NavigationLink(value: Filter.vault(v.id ?? "")) { Label(v.name, systemImage: "person.2.fill") }
                        }
                    }
                    if !session.folders.isEmpty {
                        Section("Folders") {
                            ForEach(session.folders, id: \.id) { f in
                                NavigationLink(value: Filter.folder(f.id ?? "")) { Label(f.name, systemImage: "folder.fill") }
                            }
                        }
                    }
                    Section("Categories") {
                        ForEach(ItemCategory.allCases.filter { c in session.items.contains { ItemCategory.of($0) == c } }) { c in
                            NavigationLink(value: Filter.category(c)) { Label(c.title, systemImage: c.symbol) }
                        }
                    }
                    Section {
                        NavigationLink(value: Filter.trash) { Label("Recently Deleted", systemImage: "trash") }
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Search items, sites, vaults"))
            .navigationTitle("Items")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .refreshable { try? await session.sync() }
            .navigationDestination(for: Filter.self) { ItemListView(filter: $0) }
            .navigationDestination(for: String.self) { ItemDetailView(id: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
        }
    }
}

enum Filter: Hashable {
    case all, favorites, personal, trash
    case vault(String), folder(String), category(ItemCategory), search(String)

    @MainActor func apply(_ s: Session) -> [CipherListView] {
        let live = s.items.filter { $0.deletedDate == nil }
        switch self {
        case .all: return live
        case .favorites: return live.filter(\.favorite)
        case .personal: return live.filter { $0.organizationId == nil }
        case .trash: return s.items.filter { $0.deletedDate != nil }
        case .vault(let id): return live.filter { $0.collectionIds.contains(id) }
        case .folder(let id): return live.filter { $0.folderId == id }
        case .category(let c): return live.filter { ItemCategory.of($0) == c }
        case .search(let q):
            let vaultHits = Set(s.vaults.filter { $0.name.localizedCaseInsensitiveContains(q) }.compactMap(\.id))
            return live.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
                || !vaultHits.isDisjoint(with: $0.collectionIds) || ItemCategory.of($0).title.localizedCaseInsensitiveContains(q) }
        }
    }

    @MainActor func title(_ s: Session) -> String {
        switch self {
        case .all: String(localized: "All Items")
        case .favorites: String(localized: "Favorites")
        case .personal: String(localized: "Private")
        case .trash: String(localized: "Recently Deleted")
        case .vault(let id): s.vaultName(id)
        case .folder(let id): s.folders.first { $0.id == id }?.name ?? ""
        case .category(let c): c.title
        case .search(let q): q
        }
    }
}


struct ItemListView: View {
    @Environment(Session.self) private var session
    let filter: Filter
    @State private var sort = Sort.name
    enum Sort: String, CaseIterable { case name, modified, created }

    var body: some View {
        let items = filter.apply(session).sorted {
            switch sort {
            case .name: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            case .modified: $0.revisionDate > $1.revisionDate
            case .created: $0.creationDate > $1.creationDate
            }
        }
        List(items) { i in NavigationLink(value: i.id ?? "") { ItemRow(item: i) } }
            .overlay { if items.isEmpty { ContentUnavailableView(String(localized: "Nothing here yet"), systemImage: "tray") } }
            .navigationTitle(filter.title(session))
            .toolbar {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Title").tag(Sort.name); Text("Date modified").tag(Sort.modified); Text("Date created").tag(Sort.created)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                if filter == .trash, !items.isEmpty {
                    Text("Deleted items are removed after 30 days").font(.caption2).foregroundStyle(.secondary)
                }
            }
    }
}
