import SwiftUI

struct Contact: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var timeZoneID: String
    /// Plage locale considérée comme « appelable », en heures.
    var earliest = 8
    var latest = 21
}

final class CallTimeStore: ObservableObject {
    @Published var contacts: [Contact] {
        didSet { if !applying { persist() } }
    }

    private static let key = "cockpit.calltime.contacts.v1"
    private var applying = false

    static func decode() -> [Contact] {
        if let data = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode([Contact].self, from: data) {
            return c
        }
        return [
            Contact(name: "New York", timeZoneID: "America/New_York"),
            Contact(name: "Londres", timeZoneID: "Europe/London"),
            Contact(name: "Tokyo", timeZoneID: "Asia/Tokyo"),
        ]
    }

    init() {
        contacts = Self.decode()
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let fresh = Self.decode()
            if fresh != self.contacts {
                self.applying = true
                self.contacts = fresh
                self.applying = false
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

struct CallTimeModule: View {
    @StateObject private var store = CallTimeStore()
    @State private var now = Date()
    @State private var adding = false
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.contacts) { c in
                            row(c)
                        }
                    }
                }
                Button { adding = true } label: {
                    Label("Ajouter un contact", systemImage: "plus").font(.ui(10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.info)
            }
        }
        .onReceive(tick) { now = $0 }
        .popover(isPresented: $adding) { AddContact(store: store) }
    }

    private func row(_ c: Contact) -> some View {
        let tz = TimeZone(identifier: c.timeZoneID) ?? .current
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: now)
        let good = hour >= c.earliest && hour < c.latest
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        let offset = tz.secondsFromGMT() / 3600 - TimeZone.current.secondsFromGMT() / 3600

        return HStack(spacing: 9) {
            Circle()
                .fill(good ? Theme.accent : Theme.warn)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(offset == 0 ? "même heure" : (offset > 0 ? "+\(offset) h" : "\(offset) h"))
                    .font(.ui(9)).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(f.string(from: now))
                    .font(.num(13, .semibold))
                    .foregroundStyle(good ? Theme.text : Theme.textDim)
                    .monospacedDigit()
                Text(good ? "ok pour appeler" : "hors plage")
                    .font(.ui(8.5))
                    .foregroundStyle(good ? Theme.accent : Theme.warn)
            }
            Button { store.contacts.removeAll { $0.id == c.id } } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }
}

/// Toutes les zones connues du système (la même base que l'app Horloge),
/// présentées par ville avec le décalage courant.
struct TZEntry: Identifiable {
    let id: String            // identifiant IANA
    let city: String
    let area: String          // continent / région (1er segment)
    var offsetMinutes: Int

    var offsetLabel: String {
        let sign = offsetMinutes >= 0 ? "+" : "−"
        let h = abs(offsetMinutes) / 60, m = abs(offsetMinutes) % 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }
}

enum TZCatalog {
    static let all: [TZEntry] = {
        let areaFR = ["Africa": "Afrique", "America": "Amérique", "Antarctica": "Antarctique",
                      "Arctic": "Arctique", "Asia": "Asie", "Atlantic": "Atlantique",
                      "Australia": "Australie", "Europe": "Europe", "Indian": "Océan Indien",
                      "Pacific": "Pacifique"]
        return TimeZone.knownTimeZoneIdentifiers.compactMap { id -> TZEntry? in
            let parts = id.split(separator: "/")
            guard parts.count >= 2 else { return nil }   // écarte UTC, GMT, etc.
            let city = parts.last!.replacingOccurrences(of: "_", with: " ")
            let area = areaFR[String(parts.first!)] ?? String(parts.first!)
            let off = (TimeZone(identifier: id)?.secondsFromGMT() ?? 0) / 60
            return TZEntry(id: id, city: city, area: area, offsetMinutes: off)
        }
        .sorted { $0.city < $1.city }
    }()

    static func search(_ q: String) -> [TZEntry] {
        let t = q.trimmingCharacters(in: .whitespaces).folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard !t.isEmpty else { return all }
        return all.filter {
            $0.city.folding(options: .diacriticInsensitive, locale: nil).lowercased().contains(t)
                || $0.area.folding(options: .diacriticInsensitive, locale: nil).lowercased().contains(t)
                || $0.id.lowercased().contains(t)
        }
    }
}

private struct AddContact: View {
    @ObservedObject var store: CallTimeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var selected: String?

    private var results: [TZEntry] { TZCatalog.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Nouveau contact")
            TextField("Nom (optionnel)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Rechercher une ville…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { e in
                        Button {
                            selected = e.id
                            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = e.city }
                        } label: {
                            HStack(spacing: 8) {
                                Text(e.city).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                                Text(e.area).font(.ui(10)).foregroundStyle(Theme.textFaint)
                                Spacer(minLength: 6)
                                Text(e.offsetLabel).font(.num(10.5)).foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(selected == e.id ? Theme.accent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 300, height: 220)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))

            HStack {
                Spacer()
                Button("Ajouter") {
                    guard let id = selected ?? results.first?.id else { return }
                    let n = name.trimmingCharacters(in: .whitespaces)
                    let city = TZCatalog.all.first { $0.id == id }?.city ?? id
                    store.contacts.append(Contact(name: n.isEmpty ? city : n, timeZoneID: id))
                    dismiss()
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(selected == nil && results.isEmpty)
            }
        }
        .padding(12)
    }
}
