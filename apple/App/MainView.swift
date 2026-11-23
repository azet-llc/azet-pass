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
            .modifier(SidebarOnIPad())
            .overlay(alignment: .top) { TravelBanner() }
            #if os(iOS)  // credential exchange is iPhone-only (CredentialExchange.swift)
            .modifier(CredentialImportRunner())
            #endif
            .onChange(of: prefs.deepLink) { _, _ in openLinkedTab() }
            .onAppear(perform: openLinkedTab)
        }
    }

    /// azetpass:// links: the tab here; search, new item, settings and item links finish in Items.
    private func openLinkedTab() {
        guard let link = prefs.deepLink else { return }
        tab = link.tab
        if case .tab = link { prefs.deepLink = nil }
    }
}

/// iPad and split screen: the tabs become a sidebar beside the list (iPadOS 18+); iPhone keeps the tab bar.
struct SidebarOnIPad: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) { content.tabViewStyle(.sidebarAdaptable) } else { content }
    }
}

struct TravelBanner: View {
    @Environment(Session.self) private var session
    var body: some View {
        if session.travelMode {
            Label("Travel Mode is on: only travel-safe items are on this device", systemImage: "airplane")
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
    #if os(macOS)
    @State private var update: MacUpdate?
    #endif

    private var favorites: [CipherListView] { session.items.filter { $0.favorite && $0.deletedDate == nil } }
    private var recent: [CipherListView] { session.items.filter { $0.deletedDate == nil }.sorted { $0.revisionDate > $1.revisionDate }.prefix(8).map { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    #if os(macOS)
                    if let u = update {
                        NoticeCard(title: String(localized: "A newer AZET Pass is ready"), text: String(localized: "Version \(u.version). Download it and replace this app."), symbol: "arrow.down.circle") {
                            NSWorkspace.shared.open(u.url)
                        }
                    }
                    #endif
                    if let banner = session.banner {
                        Label(banner, systemImage: "exclamationmark.triangle.fill").font(.footnote).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if session.families.isEmpty {
                        NoticeCard(title: String(localized: "Set up the whole family today"),
                                   text: String(localized: "Make a family, invite up to 4 people and fill their vaults for them. Most families finish in an afternoon."),
                                   symbol: "person.3.fill") { tab = .family }
                    }
                    NoticeCard(title: String(localized: "Scan a password notebook"),
                               text: String(localized: "Take a photo of a page. AZET Pass reads the sites, IDs and passwords on this device and lets you check each one."),
                               symbol: "camera.viewfinder") { showScan = true }
                    if !favorites.isEmpty { HomeSection(title: String(localized: "Favorites"), items: favorites, open: $open) }
                    if !recent.isEmpty { HomeSection(title: String(localized: "Recently modified"), items: recent, open: $open) }
                    if recent.isEmpty {
                        Button { showNew = true } label: { Label("Add your first item", systemImage: "plus") }.buttonStyle(.pill)
                    }
                }
                .padding(16).pageColumn()
            }
            .background(Theme.page)
            .navigationTitle("Home")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .refreshable { try? await session.sync() }
            #if os(macOS)
            .task { update = await MacUpdate.check() }
            #endif
            .navigationDestination(item: $open) { ItemDetailView(id: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
            .sheet(isPresented: $showScan) { ScanNotebookView() }
        }
    }
}

struct HomeSection: View {
    let title: String
    let items: [CipherListView]
    @Binding var open: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { n, i in
                    if n > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 52) }
                    Button { open = i.id } label: { ItemRow(item: i).padding(.vertical, 9) }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
        }
    }
}

struct ItemRow: View {
    @Environment(Session.self) private var session
    let item: CipherListView
    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(name: item.name, category: ItemCategory.of(item))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
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
            PageList {
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
            }.azetList()
            .searchable(text: $query, prompt: Text("Search items, sites, vaults"))
            .navigationTitle("Items")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .refreshable { try? await session.sync() }
            .navigationDestination(for: Filter.self) { ItemListView(filter: $0) }
            .navigationDestination(for: String.self) { ItemDetailView(id: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
            .navigationDestination(item: $linkedItem) { ItemDetailView(id: $0) }
            .onChange(of: prefs.deepLink) { _, _ in takeLink() }
            .onAppear(perform: takeLink)
        }
    }

    @Environment(Prefs.self) private var prefs
    @State private var linkedItem: String?
    private func takeLink() {
        switch prefs.deepLink {
        case .search(let q): query = q
        case .newItem: showNew = true
        case .settings: showSettings = true
        case .item(let id): linkedItem = id
        default: return
        }
        prefs.deepLink = nil
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
        PageList { ForEach(items) { i in NavigationLink(value: i.id ?? "") { ItemRow(item: i) } } }.azetList()
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
