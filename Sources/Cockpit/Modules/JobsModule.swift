import SwiftUI
import AppKit

/// Suivi des candidatures. La logique de déduction vit dans `JobsDigest` (elle
/// est aussi utilisée par l'instantané mobile) ; ce fichier ne fait que
/// l'affichage.
struct JobsModule: View {
    @ObservedObject var mail: MailModel

    private var applications: [JobApplication] {
        JobsDigest.compute(mail.sources.flatMap { mail.state($0.id).mails })
    }

    var body: some View {
        ModuleBody {
            let apps = applications
            VStack(alignment: .leading, spacing: 8) {
                if apps.isEmpty {
                    ModuleNotice(
                        icon: "briefcase",
                        title: "Aucune candidature détectée",
                        detail: "Les mails liés à une candidature (accusés, recruteurs, entretiens) apparaîtront ici automatiquement.")
                } else {
                    summary(apps)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(apps) { row($0) }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ apps: [JobApplication]) -> some View {
        let active = apps.filter { $0.stage != .rejected }
        let interviews = apps.filter { $0.stage == .interview }.count
        return HStack(spacing: 6) {
            Text("\(active.count) en cours").font(.ui(11, .semibold)).foregroundStyle(Theme.text)
            if interviews > 0 {
                Text("· \(interviews) entretien\(interviews > 1 ? "s" : "")")
                    .font(.ui(10)).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
    }

    private func stageColor(_ s: JobStage) -> Color {
        switch s {
        case .applied:   return Theme.textFaint
        case .replied:   return Theme.info
        case .interview: return Theme.accent
        case .rejected:  return Theme.warn
        }
    }

    private func row(_ a: JobApplication) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(stageColor(a.stage)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.company).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(a.lastSubject).font(.ui(9.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(a.stage.label)
                    .font(.ui(8.5, .semibold))
                    .foregroundStyle(stageColor(a.stage))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(stageColor(a.stage).opacity(0.14)))
                Text(Fmt.relday(a.lastActivity)).font(.ui(8.5)).foregroundStyle(Theme.textFaint)
            }
            if a.stage != .rejected, JobsDigest.isContactable(a.address) {
                Button { relance(a) } label: {
                    Image(systemName: "arrowshape.turn.up.right").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.info)
                .help("Relancer par mail")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private func relance(_ a: JobApplication) {
        let subject = "Suivi de ma candidature"
        let body = "Bonjour,\n\nJe me permets de revenir vers vous concernant ma candidature. "
            + "Je reste à votre disposition pour tout complément d'information.\n\nCordialement,"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = a.address
        comps.queryItems = [.init(name: "subject", value: subject), .init(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
