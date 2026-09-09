import Foundation

/// Déduction du suivi de candidatures à partir des mails « travail » repérés
/// par `MailModel`. Logique pure, partagée entre le module et l'instantané mobile.
enum JobStage: Int, Codable, Comparable {
    case applied, replied, interview, rejected
    static func < (a: JobStage, b: JobStage) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .applied:   return "Postulé"
        case .replied:   return "Réponse reçue"
        case .interview: return "Entretien"
        case .rejected:  return "Refusé"
        }
    }
}

struct JobApplication: Identifiable {
    var id: String { company.lowercased() }
    var company: String
    var address: String
    var stage: JobStage
    var lastActivity: Date
    var lastSubject: String
    var count: Int
}

enum JobsDigest {

    static func compute(_ mails: [MailModel.Mail]) -> [JobApplication] {
        var byCompany: [String: [MailModel.Mail]] = [:]
        for m in mails where m.reason == .work {
            byCompany[companyKey(m), default: []].append(m)
        }
        return byCompany.values.compactMap { msgs -> JobApplication? in
            guard let latest = msgs.max(by: { $0.date < $1.date }) else { return nil }
            let stage = msgs.map(stage(of:)).max() ?? .applied
            return JobApplication(
                company: displayCompany(latest),
                address: latest.fromAddress,
                stage: stage,
                lastActivity: latest.date,
                lastSubject: latest.subject,
                count: msgs.count)
        }
        .sorted { ($0.stage == .rejected ? 1 : 0, $1.lastActivity) < ($1.stage == .rejected ? 1 : 0, $0.lastActivity) }
    }

    static func isContactable(_ address: String) -> Bool {
        guard !address.isEmpty else { return false }
        let local = address.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        return !(local.contains("no-reply") || local.contains("noreply") || local.contains("donotreply")
            || local.contains("do-not-reply") || local.contains("notifications"))
    }

    // MARK: Déductions

    private static func companyKey(_ m: MailModel.Mail) -> String {
        let domain = m.fromAddress.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let platforms = ["lever.co", "greenhouse.io", "ashbyhq.com", "workable.com", "recruitee.com",
                         "teamtailor.com", "smartrecruiters.com", "myworkday.com", "workday.com",
                         "welcomekit.co", "welcometothejungle.com", "hellowork.com", "apec.fr",
                         "gmail.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com"]
        if platforms.contains(where: { domain.hasSuffix($0) }) || domain.isEmpty {
            return displayCompany(m).lowercased()
        }
        return domain.replacingOccurrences(of: "mail.", with: "")
                     .replacingOccurrences(of: "jobs.", with: "")
                     .replacingOccurrences(of: "careers.", with: "")
    }

    private static func displayCompany(_ m: MailModel.Mail) -> String {
        var name = m.fromName.trimmingCharacters(in: .whitespaces)
        for junk in ["Jobs at ", "Careers at ", "Recruiting at ", "The ", "Team ", "no-reply ", "Talent "] {
            if name.hasPrefix(junk) { name = String(name.dropFirst(junk.count)) }
        }
        for junk in [" Careers", " Recruiting", " Talent", " Jobs", " HR", " Team", " (via Lever)"] {
            if name.hasSuffix(junk) { name = String(name.dropLast(junk.count)) }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.contains("@") {
            let domain = m.fromAddress.split(separator: "@").last.map(String.init) ?? m.fromName
            return domain.split(separator: ".").first.map { $0.capitalized } ?? m.fromName
        }
        return name
    }

    private static func stage(of m: MailModel.Mail) -> JobStage {
        let s = m.subject.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let rejected = ["regret", "ne donnons pas suite", "ne pas donner suite", "pas retenu",
                        "non retenu", "n'a pas ete retenue", "not retained", "unfortunately",
                        "not moving forward", "not to move forward", "wish you", "autres candidat",
                        "candidature n'a pas", "decline"]
        let interview = ["entretien", "interview", "rendez-vous", "disponibilit",
                         "creneau", "call with", "meet with", "planifier", "schedule a", "scheduling",
                         "prochaine etape", "next step", "next steps", "phone screen", "visio"]
        let replied = ["candidature", "bien recu", "bien recue", "accuse de reception", "reception de",
                       "received your application", "application received", "thank you for applying",
                       "merci pour votre candidature", "reponse", "we received", "acknowledg"]
        if rejected.contains(where: s.contains) { return .rejected }
        if interview.contains(where: s.contains) { return .interview }
        if replied.contains(where: s.contains) { return .replied }
        return .applied
    }
}
