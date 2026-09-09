import SwiftUI
import AppKit

struct NewsItem: Identifiable {
    let id = UUID()
    let title: String
    let link: URL?
    let date: Date?
    let source: String
}

final class NewsModel: ObservableObject {
    @Published var items: [NewsItem] = []
    @Published var loading = false
    @Published var feeds: [String] {
        didSet { UserDefaults.standard.set(feeds, forKey: "cockpit.news.feeds") }
    }
    /// Liens déjà ouverts (clé de lecture). Persisté, capé aux 200 derniers.
    @Published var read: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cockpit.news.read") ?? [])

    func markRead(_ link: URL?) {
        guard let l = link?.absoluteString, !read.contains(l) else { return }
        read.insert(l)
        UserDefaults.standard.set(Array(read.suffix(300)), forKey: "cockpit.news.read")
        NotificationCenter.default.post(name: .cockpitLocalSettingChanged, object: nil)
    }
    var allRead: Bool { !items.isEmpty && items.allSatisfy { read.contains($0.link?.absoluteString ?? "") } }

    /// Aucun article de moins de 24 h : rien de neuf à lire, on peut replier.
    var nothingFresh: Bool {
        !items.isEmpty && !items.contains { ($0.date ?? .distantPast) > Date().addingTimeInterval(-86400) }
    }

    private static let defaults = [
        "https://www.lemonde.fr/rss/une.xml",
        "https://www.france24.com/fr/rss",
        "https://www.numerama.com/feed/",
    ]

    init() {
        feeds = (UserDefaults.standard.array(forKey: "cockpit.news.feeds") as? [String]) ?? Self.defaults
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let fresh = (UserDefaults.standard.array(forKey: "cockpit.news.feeds") as? [String]) ?? Self.defaults
            if fresh != self.feeds { self.feeds = fresh; self.refresh() }
            let r = Set(UserDefaults.standard.stringArray(forKey: "cockpit.news.read") ?? [])
            if r != self.read { self.read = r }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let list = feeds
        Task {
            var all: [NewsItem] = []
            await withTaskGroup(of: [NewsItem].self) { group in
                for f in list {
                    group.addTask { await Self.fetch(f) }
                }
                for await chunk in group { all.append(contentsOf: chunk) }
            }
            let sorted = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            await MainActor.run {
                self.items = Array(sorted.prefix(40))
                self.loading = false
            }
        }
    }

    private static func fetch(_ urlString: String) async -> [NewsItem] {
        guard let url = URL(string: urlString) else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        let parser = FeedParser(data: data)
        return parser.parse()
    }

    func resetFeeds() { feeds = Self.defaults; refresh() }
}

/// Analyseur minimal RSS 2.0 / Atom. Suffisant pour des titres et des liens.
final class FeedParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var items: [NewsItem] = []
    private var channelTitle = ""
    private var inItem = false
    private var element = ""
    private var title = ""
    private var link = ""
    private var dateString = ""
    private var atomLinkHref = ""

    init(data: Data) { self.data = data }

    func parse() -> [NewsItem] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        element = elementName
        if elementName == "item" || elementName == "entry" {
            inItem = true; title = ""; link = ""; dateString = ""; atomLinkHref = ""
        }
        if inItem, elementName == "link", let href = attributeDict["href"] {
            atomLinkHref = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else {
            if element == "title" { channelTitle += string }
            return
        }
        switch element {
        case "title": title += string
        case "link": link += string
        case "pubDate", "published", "updated", "dc:date": dateString += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" || elementName == "entry" {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlStr = (link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? atomLinkHref : link)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty {
                items.append(NewsItem(
                    title: cleanTitle,
                    link: URL(string: urlStr),
                    date: Self.parseDate(dateString.trimmingCharacters(in: .whitespacesAndNewlines)),
                    source: channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            inItem = false
        }
        element = ""
    }

    private static let formatters: [DateFormatter] = {
        let patterns = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                        "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = p
            return f
        }
    }()

    static func parseDate(_ s: String) -> Date? {
        if #available(macOS 12.0, *) {
            if let d = try? Date(s, strategy: .iso8601) { return d }
        }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}

struct NewsModule: View {
    @ObservedObject var model: NewsModel
    @State private var showConfig = false

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 6) {
                if model.items.isEmpty {
                    ModuleNotice(icon: "newspaper",
                                 title: model.loading ? "Récupération des flux…" : "Aucun article",
                                 action: ("Configurer les flux", { showConfig = true }))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.items) { row($0) }
                        }
                    }
                    HStack {
                        Text("\(model.feeds.count) flux")
                            .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button { showConfig = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
        .popover(isPresented: $showConfig) { FeedConfig(model: model) }
    }

    private func row(_ item: NewsItem) -> some View {
        let isRead = model.read.contains(item.link?.absoluteString ?? "")
        return Button {
            if let l = item.link { NSWorkspace.shared.open(l) }
            model.markRead(item.link)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.ui(11.5))
                    .foregroundStyle(isRead ? Theme.textFaint : Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(item.source).lineLimit(1)
                    if let d = item.date { Text("· \(relativeAge(d))") }
                }
                .font(.ui(9))
                .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    private func relativeAge(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 3600 { return "\(max(1, s / 60)) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) j"
    }
}

private struct FeedConfig: View {
    @ObservedObject var model: NewsModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Flux RSS (une URL par ligne)")
            TextEditor(text: $text)
                .font(.ui(10.5))
                .frame(width: 340, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            HStack {
                Button("Par défaut") { model.resetFeeds(); text = model.feeds.joined(separator: "\n") }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Enregistrer") {
                    model.feeds = text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.hasPrefix("http") }
                    model.refresh()
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .onAppear { text = model.feeds.joined(separator: "\n") }
    }
}
