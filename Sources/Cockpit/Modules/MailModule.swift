import SwiftUI
import AppKit
import Contacts

final class MailModel: ObservableObject {
    @Published var imapAccounts: [MailAccount]
    @Published private(set) var appleMailAccounts: [String] = []
    @Published private(set) var states: [String: SourceState] = [:]
    @Published var contactsGranted = false
    @Published var appleMailError: String?

    let appleMailInstalled = AppleMailBridge.isMailInstalled
    private var contactEmails: Set<String> = []
    private var timer: Timer?

    // MARK: Sources

    enum Source: Identifiable, Equatable {
        case appleMail(String)
        case imap(MailAccount)

        var id: String {
            switch self {
            case .appleMail(let n): return "am:" + n
            case .imap(let a):      return "imap:" + a.id.uuidString
            }
        }
        var name: String {
            switch self {
            case .appleMail(let n): return n
            case .imap(let a):      return a.name
            }
        }
        var viaAppleMail: Bool { if case .appleMail = self { return true } else { return false } }
    }

    /// Pour l'instant : uniquement les comptes de Mail.app.
    var sources: [Source] {
        appleMailAccounts.map(Source.appleMail)
    }

    struct SourceState {
        var loading = false
        var error: String?
        var mails: [Mail] = []
        var otherUnread = 0
        var lastSync: Date?
        /// Newsletters non lues avec un lien de désabonnement — carte à part,
        /// éphémère (disparaît une fois le mail ouvert donc lu).
        var newsletters: [Mail] = []
        var unread: Int { mails.filter { !$0.seen }.count }
    }

    struct Mail: Identifiable {
        let id: String
        var fromName: String
        var fromAddress: String
        var subject: String
        var date: Date
        var seen: Bool
        var reason: Reason
        var messageID: String
        var account: String = ""
    }

    enum Reason: Int {
        case flagged = 0, keyword = 1, work = 2, contact = 3, known = 4
        var icon: String {
            switch self {
            case .flagged: return "flag.fill"
            case .keyword: return "tag.fill"
            case .work:    return "briefcase.fill"
            case .contact: return "person.fill"
            case .known:   return "arrowshape.turn.up.left.fill"
            }
        }
        var label: String {
            switch self {
            case .flagged: return "signalé"
            case .keyword: return "mot-clé suivi"
            case .work:    return "travail / candidature"
            case .contact: return "dans tes contacts"
            case .known:   return "déjà échangé"
            }
        }
    }

    /// Mots-clés qui rendent un mail important (sujet ou expéditeur). Édités par
    /// l'utilisateur, synchronisés entre appareils via `?f=settings`.
    @Published var keywords: [String] = MailModel.loadKeywords()
    private static let keywordsKey = "cockpit.mail.keywords"
    static func loadKeywords() -> [String] {
        UserDefaults.standard.stringArray(forKey: keywordsKey) ?? []
    }
    func setKeywords(_ list: [String]) {
        var seen = Set<String>()
        let clean = list.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        keywords = clean
        UserDefaults.standard.set(clean, forKey: Self.keywordsKey)
        NotificationCenter.default.post(name: .cockpitLocalSettingChanged, object: nil)
        refreshAll()
    }

    func toggleKeyword(_ k: String) {
        if let i = keywords.firstIndex(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
            var l = keywords; l.remove(at: i); setKeywords(l)
        } else {
            setKeywords(keywords + [k])
        }
    }

    /// Mots qui annulent un mot-clé suivi quand le mail est structurellement une
    /// newsletter (en-tête List-Unsubscribe/List-Id/Precedence, cf. `isBulk`).
    /// Ne s'applique donc jamais à un vrai mail 1-à-1 : au pire on revient au
    /// comportement « avant mot-clé », jamais un mail qui n'était pas déjà écarté.
    @Published var excludes: [String] = MailModel.loadExcludes()
    private static let excludesKey = "cockpit.mail.excludes"
    static func loadExcludes() -> [String] {
        if let saved = UserDefaults.standard.array(forKey: excludesKey) as? [String] { return saved }
        // Jamais configuré : on part avec le vocabulaire publicitaire courant.
        return suggestedExcludes.flatMap { $0.1 }
    }
    func setExcludes(_ list: [String]) {
        var seen = Set<String>()
        let clean = list.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        excludes = clean
        UserDefaults.standard.set(clean, forKey: Self.excludesKey)
        NotificationCenter.default.post(name: .cockpitLocalSettingChanged, object: nil)
        refreshAll()
    }
    func toggleExclude(_ k: String) {
        if let i = excludes.firstIndex(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
            var l = excludes; l.remove(at: i); setExcludes(l)
        } else {
            setExcludes(excludes + [k])
        }
    }

    /// Vocabulaire publicitaire type (sujet), jamais présent dans un mail 1-à-1.
    static let suggestedExcludes: [(String, [String])] = [
        ("Promotions", [
            "offre spéciale", "offre exclusive", "promo", "code promo", "soldes",
            "vente flash", "black friday", "cyber monday", "french days",
            "% de réduction", "jusqu'à -", "livraison offerte", "derniers jours pour",
            "profitez-en", "ne manquez pas", "essai gratuit", "en exclusivité",
        ]),
    ]

    /// Propositions prêtes à cocher : mots qui, dans un sujet ou un expéditeur,
    /// annoncent presque toujours un message à ne pas rater.
    static let suggestedKeywords: [(String, [String])] = [
        ("Urgent / à faire", [
            "urgent", "action requise", "réponse attendue", "relance", "dernier rappel",
            "avant le", "échéance", "date limite", "à valider", "à signer", "signature",
            "merci de confirmer", "réponse souhaitée",
        ]),
        ("Argent", [
            "facture", "impayé", "paiement refusé", "prélèvement", "remboursement",
            "devis", "mise en demeure", "relevé", "trop-perçu",
        ]),
        ("Rendez-vous / santé", [
            "rendez-vous", "convocation", "confirmation de rendez-vous",
            "résultats", "ordonnance", "compte rendu",
        ]),
        ("Contrats / abonnements", [
            "résiliation", "renouvellement", "expire le", "fin de contrat",
            "préavis", "suspension", "mise à jour des conditions",
        ]),
        ("Travail / études", [
            "entretien", "candidature", "proposition", "offre", "contrat de travail",
            "recrutement", "dossier d'inscription", "admission",
        ]),
        ("Logement", [
            "bail", "loyer", "quittance", "état des lieux", "régularisation des charges",
            "assurance habitation",
        ]),
        ("Administratif", [
            "impôts", "ameli", "caf", "pôle emploi", "france travail", "urssaf",
            "carte grise", "amende", "recommandé",
        ]),
    ]

    init() {
        imapAccounts = MailAccountStore.load()
        NotificationCenter.default.addObserver(
            forName: .cockpitSettingsImported, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let freshK = MailModel.loadKeywords()
            let freshE = MailModel.loadExcludes()
            if freshK != self.keywords || freshE != self.excludes {
                self.keywords = freshK; self.excludes = freshE; self.refreshAll()
            }
        }
    }

    func start() {
        loadContacts()
        discoverAppleMail()
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        // Après un aller-retour dans les Réglages (autorisation Automatisation),
        // on retente la découverte au retour dans l'app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.appleMailInstalled, self.appleMailAccounts.isEmpty else { return }
            self.discoverAppleMail()
        }
    }

    func state(_ id: String) -> SourceState { states[id] ?? SourceState() }

    /// Expéditeurs traités (désabonné à la main, ou volontairement gardé) —
    /// leurs newsletters ne repassent plus dans la carte « Se désabonner ».
    @Published var resolvedSenders: Set<String> = MailModel.loadResolved()
    private static let resolvedKey = "cockpit.unsubscribe.resolved"
    private static func loadResolved() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: resolvedKey) ?? [])
    }
    func markResolved(_ address: String) {
        let key = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, resolvedSenders.insert(key).inserted else { return }
        UserDefaults.standard.set(Array(resolvedSenders), forKey: Self.resolvedKey)
        NotificationCenter.default.post(name: .cockpitLocalSettingChanged, object: nil)
    }

    /// Newsletters non lues avec lien de désabonnement, tous comptes confondus,
    /// hors expéditeurs déjà traités.
    var allNewsletters: [Mail] {
        sources.flatMap { state($0.id).newsletters }
            .filter { !resolvedSenders.contains($0.fromAddress.lowercased()) }
            .sorted { $0.date > $1.date }
    }

    // MARK: Découverte Mail.app

    func discoverAppleMail() {
        guard appleMailInstalled else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<[String], Error> = Result { try AppleMailBridge.accountNames() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let names):
                    self.appleMailAccounts = names
                    self.appleMailError = nil
                    for n in names { self.refresh(.appleMail(n)) }
                case .failure(let error):
                    self.appleMailError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Comptes IMAP directs

    func addPasswordAccount(_ account: MailAccount, password: String) {
        imapAccounts.append(account)
        MailAccountStore.save(imapAccounts)
        MailAccountStore.update(account.id) { $0.password = password }
        refresh(.imap(account))
    }

    func addOAuthAccount(_ account: MailAccount, clientSecret: String, tokens: OAuthTokens) {
        imapAccounts.append(account)
        MailAccountStore.save(imapAccounts)
        MailAccountStore.update(account.id) { $0.clientSecret = clientSecret; $0.tokens = tokens }
        refresh(.imap(account))
    }

    func removeIMAP(_ id: UUID) {
        imapAccounts.removeAll { $0.id == id }
        MailAccountStore.save(imapAccounts)
        MailAccountStore.delete(id)
        states["imap:" + id.uuidString] = nil
    }

    func hasCredential(_ acc: MailAccount) -> Bool {
        let s = MailAccountStore.secrets(for: acc.id)
        return acc.auth.isOAuth ? (s.tokens != nil) : (s.password != nil)
    }

    func setPassword(_ password: String, for id: UUID) {
        MailAccountStore.update(id) { $0.password = password }
        if let acc = imapAccounts.first(where: { $0.id == id }) { refresh(.imap(acc)) }
    }

    // MARK: Rafraîchissement

    func refreshAll() { sources.forEach(refresh) }

    func refresh(_ source: Source) {
        let contacts = contactEmails
        let sid = source.id
        update(sid) { $0.loading = true; $0.error = nil }

        switch source {
        case .appleMail(let name):
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result: Result<([Mail], Int, [Mail]), Error>
                do {
                    let fetch = try AppleMailBridge.fetch(account: name)
                    result = .success(Self.digest(fetch, contacts: contacts, account: name))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { self?.apply(result, to: sid) }
            }

        case .imap(let account):
            guard hasCredential(account) else {
                update(sid) { $0.loading = false; $0.error = account.auth.isOAuth
                    ? "Reconnexion nécessaire" : "Mot de passe manquant" }
                return
            }
            Task { [weak self] in
                let result: Result<([Mail], Int, [Mail]), Error>
                do {
                    let auth = try await Self.authorization(for: account)
                    let client = IMAPClient(host: account.host, port: account.port)
                    let fetch = try await client.fetchImportant(user: account.username, auth: auth)
                    result = .success(Self.digest(fetch, contacts: contacts, account: account.name))
                } catch { result = .failure(error) }
                await MainActor.run { [weak self] in self?.apply(result, to: sid) }
            }
        }
    }

    private func apply(_ result: Result<([Mail], Int, [Mail]), Error>, to sid: String) {
        switch result {
        case .success(let (mails, unread, newsletters)):
            update(sid) {
                $0.loading = false; $0.mails = mails
                $0.otherUnread = unread; $0.newsletters = newsletters; $0.lastSync = Date()
            }
        case .failure(let error):
            update(sid) {
                $0.loading = false
                $0.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private static func authorization(for account: MailAccount) async throws -> IMAPClient.Auth {
        switch account.auth {
        case .password:
            guard let pw = MailAccountStore.secrets(for: account.id).password else {
                throw IMAPError.login("mot de passe manquant")
            }
            return .password(pw)
        case .oauth(let provider, let clientID):
            var s = MailAccountStore.secrets(for: account.id)
            guard var tokens = s.tokens else { throw IMAPError.oauthRequired }
            if !tokens.isFresh {
                tokens = try await OAuthFlow.refresh(
                    provider: provider, clientID: clientID,
                    clientSecret: s.clientSecret ?? "", refreshToken: tokens.refreshToken)
                s.tokens = tokens
                MailAccountStore.update(account.id) { $0.tokens = tokens }
            }
            return .xoauth2(token: tokens.accessToken)
        }
    }

    /// Tri « important » : signalé, ou travail/candidature, ou contact, ou
    /// correspondant déjà connu. Les listes / newsletters sont écartées.
    private static func digest(_ fetch: MailFetch, contacts: Set<String>, account: String) -> ([Mail], Int, [Mail]) {
        var mails: [Mail] = []
        var otherUnread = 0
        var newsletters: [Mail] = []
        let keywords = loadKeywords().map { $0.folding(options: .diacriticInsensitive, locale: nil).lowercased() }
        let excludes = loadExcludes().map { $0.folding(options: .diacriticInsensitive, locale: nil).lowercased() }
        for m in fetch.messages {
            let email = m.fromAddress.lowercased()
            let hay = (m.subject + " " + m.fromName + " " + email)
                .folding(options: .diacriticInsensitive, locale: nil).lowercased()

            // Carte « Se désabonner » : indépendante du tri importance, tant
            // que le mail n'est pas lu (elle se vide toute seule une fois ouvert).
            if !m.seen && m.hasUnsubscribeLink {
                newsletters.append(Mail(id: "\(account)-\(m.uid)-\(email)", fromName: m.fromName,
                                        fromAddress: email, subject: m.subject, date: m.date,
                                        seen: m.seen, reason: .known, messageID: m.messageID, account: account))
            }

            let reason: Reason?
            // Signalé ou mot-clé suivi : passe toujours, même si c'est une « liste ».
            // Sauf si le mail est structurellement une newsletter (isBulk) ET contient
            // un mot d'exclusion (vocabulaire publicitaire) : là, le mot-clé ne force
            // plus le passage — on retombe sur le filtre newsletter normal.
            let keywordHit = keywords.contains(where: hay.contains)
            let excludedAsAd = m.isBulk && excludes.contains(where: hay.contains)
            if m.flagged { reason = .flagged }
            else if keywordHit && !excludedAsAd { reason = .keyword }
            else if m.isBulk { continue }
            else if isWorkRelated(m) { reason = .work }
            else if contacts.contains(email) { reason = .contact }
            else if fetch.knownCorrespondents.contains(email) { reason = .known }
            else { reason = nil }

            if let reason {
                mails.append(Mail(id: "\(account)-\(m.uid)-\(email)", fromName: m.fromName, fromAddress: email,
                                  subject: m.subject, date: m.date, seen: m.seen, reason: reason,
                                  messageID: m.messageID, account: account))
            } else if !m.seen {
                otherUnread += 1
            }
        }
        mails.sort { ($0.seen ? 1 : 0, $1.date) < ($1.seen ? 1 : 0, $0.date) }
        newsletters.sort { $0.date > $1.date }
        return (mails, otherUnread, newsletters)
    }

    /// Contexte professionnel : candidature, réponse de recruteur, entretien…
    private static let workTerms = [
        "candidature", "candidat", "postul", "recrut", "entretien", "embauche",
        "offre d'emploi", "lettre de motivation", "recruteur", "ressources humaines",
        "opportunité", "opportunit", "poste de", "poste à", "poste chez", "cdi", "cdd",
        "stage", "alternance", "freelance", "prestation", "mission",
        "hiring", "recruit", "interview", "job offer", "job application",
        "your application", "we received your application", "application received",
        "next steps", "talent acquisition", "career opportunity", "position at",
        "candidacy", "cover letter",
    ]
    private static let workDomains = [
        "lever.co", "greenhouse.io", "ashbyhq.com", "workable.com", "recruitee.com",
        "teamtailor.com", "smartrecruiters.com", "myworkday.com", "workday.com",
        "welcomekit.co", "welcometothejungle.com", "hellowork.com", "apec.fr",
    ]

    private static func isWorkRelated(_ m: RawMessage) -> Bool {
        let haystack = (m.subject + " " + m.fromName).lowercased()
        if workTerms.contains(where: haystack.contains) { return true }
        let domain = m.fromAddress.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return workDomains.contains { domain.hasSuffix($0) }
    }

    private func update(_ id: String, _ change: (inout SourceState) -> Void) {
        var s = states[id] ?? SourceState()
        change(&s)
        states[id] = s
    }

    // MARK: Contacts

    func loadContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.contactsGranted = granted }
            guard granted else { return }
            DispatchQueue.global(qos: .utility).async {
                var emails = Set<String>()
                let req = CNContactFetchRequest(keysToFetch: [CNContactEmailAddressesKey as CNKeyDescriptor])
                try? store.enumerateContacts(with: req) { contact, _ in
                    for e in contact.emailAddresses {
                        emails.insert((e.value as String).lowercased().trimmingCharacters(in: .whitespaces))
                    }
                }
                DispatchQueue.main.async { self?.contactEmails = emails }
            }
        }
    }

    /// Ouvre le mail dans Mail.app via le schéma `message:`.
    func openInMail(_ mail: Mail) {
        guard !mail.messageID.isEmpty else { NSWorkspace.shared.open(URL(string: "mailto:")!); return }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@!$&'()*+,;=:")
        let encoded = mail.messageID.addingPercentEncoding(withAllowedCharacters: allowed) ?? mail.messageID
        if let url = URL(string: "message://%3c\(encoded)%3e") {
            NSWorkspace.shared.open(url)
        }
    }

    func openContactsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Vue

struct MailModule: View {
    @ObservedObject var model: MailModel
    /// `nil` = onglet « Tout » (vue par défaut, agrège tous les comptes).
    @State private var selectedID: String?
    @State private var showKeywords = false

    private var current: MailModel.Source? {
        guard let id = selectedID else { return nil }
        return model.sources.first { $0.id == id }
    }
    private var isAll: Bool { selectedID == nil }

    /// État agrégé de tous les comptes pour l'onglet « Tout ».
    private var allState: MailModel.SourceState {
        var st = MailModel.SourceState()
        var seen = Set<String>()
        var mails: [MailModel.Mail] = []
        for src in model.sources {
            let s = model.state(src.id)
            st.loading = st.loading || s.loading
            st.otherUnread += s.otherUnread
            if let ls = s.lastSync { st.lastSync = max(st.lastSync ?? .distantPast, ls) }
            for m in s.mails where seen.insert(m.messageID.isEmpty ? m.id : m.messageID).inserted {
                mails.append(m)
            }
        }
        mails.sort { ($0.seen ? 1 : 0, $1.date) < ($1.seen ? 1 : 0, $0.date) }
        st.mails = mails
        return st
    }

    var body: some View {
        ModuleBody {
            VStack(alignment: .leading, spacing: 0) {
                if model.sources.isEmpty {
                    emptyState
                } else {
                    if let e = model.appleMailError, model.appleMailInstalled {
                        appleMailBanner(e)
                    }
                    tabs
                    Divider().overlay(Theme.hairline).padding(.vertical, 6)
                    if isAll {
                        list(allState, retry: nil, showAccount: model.sources.count > 1)
                    } else if let src = current {
                        list(model.state(src.id), retry: { model.refresh(src) }, showAccount: false)
                    }
                    footer
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope").font(.system(size: 18)).foregroundStyle(Theme.textFaint)
            if !model.appleMailInstalled {
                Text("Mail.app introuvable").font(.ui(12, .medium)).foregroundStyle(Theme.textDim)
            } else if model.appleMailError != nil {
                Text("Autorise Cockpit à lire Mail").font(.ui(12, .medium)).foregroundStyle(Theme.textDim)
                Text(model.appleMailError ?? "").font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir les réglages") { model.openAutomationSettings() }
                    .buttonStyle(GhostButtonStyle())
                Button("Réessayer") { model.discoverAppleMail() }
                    .buttonStyle(.plain).font(.ui(10)).foregroundStyle(Theme.info)
            } else {
                Text("Aucun compte dans Mail.app").font(.ui(12, .medium)).foregroundStyle(Theme.textDim)
                Text("Ajoute tes adresses (Gmail, Outlook, iCloud…) dans Réglages Système › Comptes Internet. Elles apparaîtront ici automatiquement.")
                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir Comptes Internet") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts")!)
                }
                .buttonStyle(GhostButtonStyle())
                Button("Réessayer") { model.discoverAppleMail() }
                    .buttonStyle(.plain).font(.ui(10)).foregroundStyle(Theme.info)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appleMailBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "envelope.badge").font(.system(size: 10)).foregroundStyle(Theme.warn)
            Text(error).font(.ui(9)).foregroundStyle(Theme.textDim).lineLimit(2)
            Spacer(minLength: 4)
            Button("Autoriser") { model.openAutomationSettings() }
                .buttonStyle(.plain).font(.ui(9, .semibold)).foregroundStyle(Theme.info)
            Button { model.discoverAppleMail() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 8))
            }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.warn.opacity(0.08)))
        .padding(.bottom, 6)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(name: "Tout", icon: "tray.2", selected: isAll,
                    loading: model.sources.contains { model.state($0.id).loading },
                    badge: model.sources.reduce(0) { $0 + model.state($1.id).unread }) {
                    selectedID = nil
                }
                ForEach(model.sources) { src in
                    let s = model.state(src.id)
                    tab(name: src.name, icon: src.viaAppleMail ? "envelope.circle.fill" : nil,
                        selected: selectedID == src.id, loading: s.loading, badge: s.unread) {
                        selectedID = src.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tab(name: String, icon: String?, selected: Bool, loading: Bool,
                     badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                }
                Text(name).font(.ui(11, .medium)).lineLimit(1)
                if loading {
                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                } else if badge > 0 {
                    Text("\(badge)").font(.num(9, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.05)))
            .foregroundStyle(selected ? Theme.text : Theme.textDim)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func list(_ s: MailModel.SourceState, retry: (() -> Void)?, showAccount: Bool) -> some View {
        if let e = s.error, let retry {
            ModuleNotice(icon: "exclamationmark.triangle", title: e, action: ("Réessayer", retry))
        } else if s.mails.isEmpty && !s.loading {
            VStack(spacing: 4) {
                Text("Rien d'important").font(.ui(11)).foregroundStyle(Theme.textFaint)
                if s.otherUnread > 0 {
                    Text("\(s.otherUnread) autres non lus").font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.mails) { row($0, showAccount: showAccount) }
                    if s.otherUnread > 0 {
                        Text("+ \(s.otherUnread) autres non lus (hors listes)")
                            .font(.ui(9.5)).foregroundStyle(Theme.textFaint).padding(.top, 4)
                    }
                }
            }
        }
    }

    private func row(_ m: MailModel.Mail, showAccount: Bool) -> some View {
        Button { model.openInMail(m) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(m.seen ? Color.clear : Theme.accent)
                    .frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(m.fromName)
                            .font(.ui(12, m.seen ? .regular : .semibold))
                            .foregroundStyle(Theme.text).lineLimit(1)
                        Image(systemName: m.reason.icon)
                            .font(.system(size: 7)).foregroundStyle(Theme.textFaint)
                            .help(m.reason.label)
                        Spacer(minLength: 4)
                        Text(Fmt.relday(m.date)).font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                    }
                    HStack(spacing: 5) {
                        if showAccount && !m.account.isEmpty {
                            Text(m.account.uppercased())
                                .font(.ui(7.5, .semibold)).foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 3).padding(.vertical, 0.5)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
                        }
                        Text(m.subject).font(.ui(11)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ouvrir dans Mail")
    }

    private var footer: some View {
        let sync = isAll ? allState.lastSync : current.map { model.state($0.id).lastSync } ?? nil
        return HStack(spacing: 6) {
            if let sync {
                Text("maj \(Fmt.shortTime(sync))").font(.ui(9)).foregroundStyle(Theme.textFaint)
            }
            if !model.contactsGranted {
                Button("Autoriser Contacts") { model.openContactsSettings() }
                    .buttonStyle(.plain).font(.ui(9)).foregroundStyle(Theme.info)
            }
            Spacer()
            Button { showKeywords = true } label: {
                Image(systemName: "tag").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.keywords.isEmpty ? Theme.textFaint : Theme.accent)
            .help("Mots-clés importants")
            .popover(isPresented: $showKeywords) { KeywordEditor(model: model) }
            Button {
                if let src = current { model.refresh(src) } else { model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .padding(.top, 4)
    }
}

private struct KeywordEditor: View {
    @ObservedObject var model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var tab = 0   // 0 = suivis, 1 = exclusions

    private func has(_ k: String) -> Bool {
        model.keywords.contains { $0.caseInsensitiveCompare(k) == .orderedSame }
    }
    private func hasExclude(_ k: String) -> Bool {
        model.excludes.contains { $0.caseInsensitiveCompare(k) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text("Mots suivis").tag(0)
                Text("Exclusions").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            if tab == 0 {
                SectionLabel(text: "Mots-clés importants")
                Text("Un mail dont le sujet ou l'expéditeur contient l'un de ces mots passe en important, même s'il ressemble à une newsletter.")
                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        // Ceux ajoutés à la main qui ne sont pas dans les propositions.
                        let suggested = Set(MailModel.suggestedKeywords.flatMap { $0.1 }.map { $0.lowercased() })
                        let mine = model.keywords.filter { !suggested.contains($0.lowercased()) }
                        if !mine.isEmpty { chipGroup("Les tiens", mine, isOn: has, toggle: model.toggleKeyword) }
                        ForEach(MailModel.suggestedKeywords, id: \.0) { section in
                            chipGroup(section.0, section.1, isOn: has, toggle: model.toggleKeyword)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 300, height: 220)

                addField(placeholder: "ajouter un mot…") { model.toggleKeyword($0) }
            } else {
                SectionLabel(text: "Mots qui annulent")
                Text("Si un mail « suivi » ci-contre a aussi un en-tête de newsletter (lien de désinscription) ET l'un de ces mots, il n'est plus considéré comme important — sinon le tri newsletter s'applique normalement.")
                    .font(.ui(9.5)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        let suggested = Set(MailModel.suggestedExcludes.flatMap { $0.1 }.map { $0.lowercased() })
                        let mine = model.excludes.filter { !suggested.contains($0.lowercased()) }
                        if !mine.isEmpty { chipGroup("Les tiens", mine, isOn: hasExclude, toggle: model.toggleExclude) }
                        ForEach(MailModel.suggestedExcludes, id: \.0) { section in
                            chipGroup(section.0, section.1, isOn: hasExclude, toggle: model.toggleExclude)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 300, height: 220)

                addField(placeholder: "ajouter une expression…") { model.toggleExclude($0) }
            }

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(GhostButtonStyle(prominent: true))
            }
        }
        .padding(12)
    }

    private func addField(placeholder: String, add: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $custom)
                .textFieldStyle(.roundedBorder).font(.ui(11))
                .onSubmit { addCustom(add) }
            Button("Ajouter") { addCustom(add) }
                .buttonStyle(GhostButtonStyle())
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addCustom(_ add: (String) -> Void) {
        let k = custom.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        add(k)
        custom = ""
    }

    @ViewBuilder
    private func chipGroup(_ title: String, _ words: [String],
                            isOn: @escaping (String) -> Bool, toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.ui(8.5, .semibold)).foregroundStyle(Theme.textFaint).tracking(0.4)
            FlowChips(words: words, isOn: isOn, toggle: toggle)
        }
    }
}

/// Petit wrap de « chips » cochables.
private struct FlowChips: View {
    let words: [String]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        FlexWrap(words, spacing: 5) { w in
            Button { toggle(w) } label: {
                Text(w).font(.ui(10.5))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(isOn(w) ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isOn(w) ? Theme.accent.opacity(0.6) : Theme.hairline))
                    .foregroundStyle(isOn(w) ? Theme.text : Theme.textDim)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Layout « wrap » horizontal (chips qui passent à la ligne).
private struct FlexWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 6, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.spacing = spacing; self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}


/// « Se désabonner » : newsletters non lues avec un lien de désabonnement
/// détecté (en-tête List-Unsubscribe). Carte éphémère — n'apparaît que s'il y
/// a quelque chose, et chaque ligne disparaît d'elle-même une fois le mail
/// ouvert (donc marqué lu). Cliquer une ligne ouvre le mail dans Mail.
struct UnsubscribeModule: View {
    @ObservedObject var model: MailModel

    var body: some View {
        ModuleBody {
            if model.allNewsletters.isEmpty {
                ModuleNotice(icon: "bell.slash", title: "Rien à désabonner")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.allNewsletters) { row($0) }
                    }
                }
            }
        }
    }

    private func row(_ m: MailModel.Mail) -> some View {
        HStack(spacing: 8) {
            Button { model.openInMail(m) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.textFaint).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.fromName).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(m.subject).font(.ui(9.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.relday(m.date)).font(.ui(9)).foregroundStyle(Theme.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ouvrir dans Mail")

            Button { model.markResolved(m.fromAddress) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle").font(.system(size: 10))
                    Text("Traité").font(.ui(9.5, .medium))
                }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Je m'y suis désabonné — ne plus proposer ce contact")

            Button { model.markResolved(m.fromAddress) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "bell").font(.system(size: 10))
                    Text("Garder").font(.ui(9.5, .medium))
                }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
            .help("Mail normal, je veux le garder — ne plus proposer ce contact")
        }
        .padding(.vertical, 3)
    }
}
