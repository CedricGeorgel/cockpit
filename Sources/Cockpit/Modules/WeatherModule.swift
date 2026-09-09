import SwiftUI

struct WeatherSnapshot {
    var place: String
    var temp: Double
    var feels: Double
    var code: Int
    var humidity: Int
    var wind: Double
    var tempMax: Double
    var tempMin: Double
    var precipProb: Int
    var aqi: Int?
    var pm25: Double?
    var topPollen: (name: String, value: Double)?
}

final class WeatherModel: ObservableObject {
    @Published var snapshot: WeatherSnapshot?
    @Published var error: String?
    @Published var loading = false
    @Published var place: String {
        didSet { UserDefaults.standard.set(place, forKey: "cockpit.weather.place") }
    }
    /// Accordéon des détails ouvert : la carte réclame plus de hauteur.
    @Published var detailsOpen = UserDefaults.standard.bool(forKey: "cockpit.weather.details") {
        didSet { UserDefaults.standard.set(detailsOpen, forKey: "cockpit.weather.details") }
    }

    init() {
        place = UserDefaults.standard.string(forKey: "cockpit.weather.place") ?? ""
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            let fresh = UserDefaults.standard.string(forKey: "cockpit.weather.place") ?? ""
            if fresh != self?.place { self?.place = fresh; self?.refresh() }
        }
    }

    var hasPlace: Bool { !place.trimmingCharacters(in: .whitespaces).isEmpty }

    func refresh() {
        let query = place.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { snapshot = nil; error = nil; return }
        loading = true
        error = nil
        Task { await load(query: query) }
    }

    @MainActor
    private func set(_ snap: WeatherSnapshot?, _ err: String?) {
        snapshot = snap; error = err; loading = false
    }

    private func load(query: String) async {
        // On garde le dernier relevé valable pendant qu'on retente : une faute de
        // frappe ne doit pas vider la carte (et laisser la ville toujours éditable).
        let previous = await MainActor.run { snapshot }
        do {
            guard let geo = try await geocode(query) else {
                await set(previous, "« \(query) » : ville introuvable"); return
            }
            async let forecast = fetchForecast(lat: geo.lat, lon: geo.lon)
            async let air = fetchAir(lat: geo.lat, lon: geo.lon)
            var snap = try await forecast
            snap.place = geo.name
            let a = try? await air
            snap.aqi = a?.aqi
            snap.pm25 = a?.pm25
            snap.topPollen = a?.topPollen
            await set(snap, nil)
        } catch {
            await set(previous, "Réseau indisponible")
        }
    }

    // MARK: Requêtes

    private struct Geo { let name: String; let lat: Double; let lon: Double }

    private func geocode(_ q: String) async throws -> Geo? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "1"),
                        .init(name: "language", value: "fr")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        struct R: Decodable { struct Item: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String? }
            let results: [Item]? }
        guard let item = try JSONDecoder().decode(R.self, from: data).results?.first else { return nil }
        return Geo(name: item.name, lat: item.latitude, lon: item.longitude)
    }

    private func fetchForecast(lat: Double, lon: Double) async throws -> WeatherSnapshot {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        struct R: Decodable {
            struct Cur: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let relative_humidity_2m: Double
                let weather_code: Int
                let wind_speed_10m: Double
            }
            struct Day: Decodable {
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let precipitation_probability_max: [Int?]
            }
            let current: Cur
            let daily: Day
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return WeatherSnapshot(
            place: "", temp: r.current.temperature_2m, feels: r.current.apparent_temperature,
            code: r.current.weather_code, humidity: Int(r.current.relative_humidity_2m.rounded()),
            wind: r.current.wind_speed_10m,
            tempMax: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
            tempMin: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
            precipProb: r.daily.precipitation_probability_max.first.flatMap { $0 } ?? 0,
            aqi: nil, pm25: nil, topPollen: nil)
    }

    private struct AirResult { let aqi: Int?; let pm25: Double?; let topPollen: (name: String, value: Double)? }

    private func fetchAir(lat: Double, lon: Double) async throws -> AirResult {
        var c = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "european_aqi,pm2_5,alder_pollen,birch_pollen,grass_pollen,mugwort_pollen,olive_pollen,ragweed_pollen"),
            .init(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        struct R: Decodable {
            struct Cur: Decodable {
                let european_aqi: Double?
                let pm2_5: Double?
                let alder_pollen: Double?
                let birch_pollen: Double?
                let grass_pollen: Double?
                let mugwort_pollen: Double?
                let olive_pollen: Double?
                let ragweed_pollen: Double?
            }
            let current: Cur
        }
        let cur = try JSONDecoder().decode(R.self, from: data).current
        let pollens: [(String, Double?)] = [
            ("aulne", cur.alder_pollen), ("bouleau", cur.birch_pollen),
            ("graminées", cur.grass_pollen), ("armoise", cur.mugwort_pollen),
            ("olivier", cur.olive_pollen), ("ambroisie", cur.ragweed_pollen),
        ]
        let top = pollens.compactMap { n, v in v.map { (n, $0) } }
            .filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        return AirResult(aqi: cur.european_aqi.map { Int($0.rounded()) },
                         pm25: cur.pm2_5, topPollen: top)
    }
}

// MARK: - Vue

struct WeatherModule: View {
    @ObservedObject var model: WeatherModel
    @State private var editingPlace = false
    @State private var draft = ""
    private var showDetails: Bool { model.detailsOpen }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 10) {
                if let s = model.snapshot {
                    header(s)
                    if let e = model.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.ui(10)).foregroundStyle(Theme.warn)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    detailsAccordion(s)
                } else if !model.hasPlace {
                    ModuleNotice(icon: "location.magnifyingglass", title: "Choisissez une ville",
                                 action: ("Définir la ville", { draft = ""; editingPlace = true }))
                        .popover(isPresented: $editingPlace) { placeEditor }
                } else if let e = model.error {
                    ModuleNotice(icon: "location.slash", title: e,
                                 action: ("Changer de ville", { draft = model.place; editingPlace = true }))
                        .popover(isPresented: $editingPlace) { placeEditor }
                } else {
                    ModuleNotice(icon: "cloud.sun", title: "Chargement…")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ s: WeatherSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: wmoIcon(s.code))
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(wmoColor(s.code))
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(Int(s.temp.rounded()))°")
                        .font(.num(30, .semibold))
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("max \(Int(s.tempMax.rounded()))°  min \(Int(s.tempMin.rounded()))°")
                            .font(.ui(10.5)).foregroundStyle(Theme.textDim)
                        Text("ressenti \(Int(s.feels.rounded()))°")
                            .font(.ui(10.5)).foregroundStyle(Theme.textFaint)
                    }
                }
                Text(wmoText(s.code))
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.textDim)
                Button {
                    draft = model.place; editingPlace = true
                } label: {
                    Label(s.place, systemImage: "location.fill")
                        .font(.ui(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .popover(isPresented: $editingPlace) { placeEditor }
    }

    private var placeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ville").font(.ui(10, .semibold)).foregroundStyle(Theme.textFaint)
            HStack {
                TextField("Paris, Lyon, Berlin…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { commit() }
                Button("OK") { commit() }.buttonStyle(GhostButtonStyle(prominent: true))
            }
        }
        .padding(12)
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { model.place = t; model.refresh() }
        editingPlace = false
    }

    @ViewBuilder
    private func detailsAccordion(_ s: WeatherSnapshot) -> some View {
        Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { model.detailsOpen.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(showDetails ? "Masquer les détails" : summary(s))
                    .font(.ui(10.5)).foregroundStyle(Theme.textFaint)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(showDetails ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showDetails {
            Divider().overlay(Theme.hairline)
            grid(s)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Résumé d'une ligne quand l'accordéon est replié.
    private func summary(_ s: WeatherSnapshot) -> String {
        var parts = ["\(s.humidity) % hum.", "\(Int(s.wind.rounded())) km/h", "pluie \(s.precipProb) %"]
        if let a = s.aqi { parts.append("air \(aqiLabel(a))") }
        return parts.joined(separator: " · ")
    }

    private func grid(_ s: WeatherSnapshot) -> some View {
        let items: [(String, String, String)] = [
            ("humidity", "Humidité", "\(s.humidity) %"),
            ("wind", "Vent", "\(Int(s.wind.rounded())) km/h"),
            ("umbrella", "Pluie", "\(s.precipProb) %"),
            ("aqi", "Qualité air", s.aqi.map { "\($0) · \(aqiLabel($0))" } ?? "n/c"),
            ("pollen", "Pollen", s.topPollen.map { "\($0.name) \(pollenLabel($0.value))" } ?? "faible"),
        ]
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.1) { icon, label, value in
                HStack(spacing: 8) {
                    Image(systemName: sfFor(icon))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 16)
                    Text(label)
                        .font(.ui(11))
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 6)
                    Text(value)
                        .font(.num(11.5, .medium))
                        .foregroundStyle(iconColor(icon, value))
                }
            }
        }
    }

    private func sfFor(_ k: String) -> String {
        switch k {
        case "humidity": return "humidity.fill"
        case "wind": return "wind"
        case "umbrella": return "umbrella.fill"
        case "aqi": return "aqi.medium"
        case "pollen": return "leaf.fill"
        default: return "circle"
        }
    }

    private func iconColor(_ k: String, _ value: String) -> Color {
        Theme.text
    }
}

// MARK: - Barèmes

func aqiLabel(_ v: Int) -> String {
    switch v {
    case ..<20: return "très bon"
    case ..<40: return "bon"
    case ..<60: return "moyen"
    case ..<80: return "médiocre"
    case ..<100: return "mauvais"
    default: return "très mauvais"
    }
}

func pollenLabel(_ v: Double) -> String {
    switch v {
    case ..<10: return "(faible)"
    case ..<50: return "(modéré)"
    case ..<200: return "(élevé)"
    default: return "(très élevé)"
    }
}

func wmoText(_ code: Int) -> String {
    switch code {
    case 0: return "Ciel dégagé"
    case 1: return "Plutôt dégagé"
    case 2: return "Partiellement nuageux"
    case 3: return "Couvert"
    case 45, 48: return "Brouillard"
    case 51, 53, 55: return "Bruine"
    case 56, 57: return "Bruine verglaçante"
    case 61, 63, 65: return "Pluie"
    case 66, 67: return "Pluie verglaçante"
    case 71, 73, 75: return "Neige"
    case 77: return "Grains de neige"
    case 80, 81, 82: return "Averses"
    case 85, 86: return "Averses de neige"
    case 95: return "Orage"
    case 96, 99: return "Orage grêleux"
    default: return "Conditions variables"
    }
}

/// Couleur de l'icône (visible en thème clair comme sombre).
func wmoColor(_ code: Int) -> Color {
    switch code {
    case 0, 1:                     return Color(red: 0.95, green: 0.68, blue: 0.20)   // soleil
    case 2:                        return Color(red: 0.55, green: 0.68, blue: 0.82)   // éclaircies
    case 3, 45, 48:                return Color(red: 0.55, green: 0.58, blue: 0.63)   // couvert / brouillard
    case 51...67, 80...82:         return Color(red: 0.30, green: 0.52, blue: 0.78)   // pluie
    case 71...77, 85, 86:          return Color(red: 0.62, green: 0.74, blue: 0.85)   // neige
    case 95...99:                  return Color(red: 0.42, green: 0.38, blue: 0.62)   // orage
    default:                       return Color(red: 0.55, green: 0.58, blue: 0.63)
    }
}

/// Teinte de fond de la carte, façon météo.
func wmoTint(_ code: Int) -> Color {
    switch code {
    case 0, 1:              return Color(red: 0.42, green: 0.66, blue: 0.95)   // bleu ciel
    case 2:                 return Color(red: 0.50, green: 0.62, blue: 0.80)
    case 3, 45, 48:         return Color(red: 0.55, green: 0.58, blue: 0.62)   // gris
    case 51...67, 80...82:  return Color(red: 0.28, green: 0.45, blue: 0.68)   // bleu pluie
    case 71...77, 85, 86:   return Color(red: 0.70, green: 0.78, blue: 0.88)   // blanc bleuté
    case 95...99:           return Color(red: 0.40, green: 0.35, blue: 0.58)   // violet orage
    default:                return Color(red: 0.55, green: 0.58, blue: 0.62)
    }
}

func wmoIcon(_ code: Int) -> String {
    switch code {
    case 0: return "sun.max.fill"
    case 1, 2: return "cloud.sun.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
    case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
    case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
    case 95, 96, 99: return "cloud.bolt.rain.fill"
    default: return "cloud.fill"
    }
}
