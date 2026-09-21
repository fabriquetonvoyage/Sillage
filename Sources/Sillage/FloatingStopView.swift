import SwiftUI

/// Contenu du panneau flottant : pastille rouge, chrono, niveau du micro et
/// bouton Stop, sur un fond Liquid Glass translucide (macOS 26).
///
/// Le niveau du micro est là pour une raison précise : un flux d'entrée peut
/// être ouvert et parfaitement muet (mauvais périphérique, micro coupé, casque
/// Bluetooth en HFP tenu par une autre app). Sans témoin visible, on ne s'en
/// aperçoit qu'à la fin, transcript vide à l'appui.
struct FloatingStopView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(controller.elapsedString)
                    .font(.headline)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: controller.micSeemsSilent ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(controller.micSeemsSilent ? .orange : .secondary)
                MicLevelBar(level: controller.micLevel, alert: controller.micSeemsSilent)
                if controller.micSeemsSilent {
                    Text("micro muet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let name = controller.activeInputName {
                    // Nommer le micro réellement ouvert : « Défaut système » ne
                    // dit pas lequel c'est, et c'est là que ça dérape.
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 130)
                }
            }
            .help(controller.micSeemsSilent
                  ? "Aucun son capté : le micro sélectionné n'est probablement pas celui dans lequel vous parlez."
                  : "Niveau du micro")

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.red)
                    .padding(4)
            }
            .buttonStyle(.glass)
            .help("Arrêter l'enregistrement")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .padding(10)   // marge pour le halo du glass
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: controller.micSeemsSilent)
    }
}

/// Petite jauge horizontale. Échelle en racine carrée : la parole normale
/// occupe une bonne moitié de la barre plutôt qu'un filet à gauche.
private struct MicLevelBar: View {
    let level: Float
    let alert: Bool

    private var filled: CGFloat {
        CGFloat(min(1, sqrt(max(0, level)) * 1.6))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(alert ? Color.orange : Color.green)
                    .frame(width: max(2, geo.size.width * filled))
            }
        }
        .frame(width: 52, height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}
