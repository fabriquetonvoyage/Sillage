import SwiftUI
import CoreAudio

struct ContentView: View {
    @EnvironmentObject var controller: RecordingController
    @EnvironmentObject private var selection: TranscriptSelection
    @Environment(\.openWindow) private var openWindow
    @State private var recents: [TranscriptItem] = []
    @State private var justCopiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sillage").font(.headline)

            // Actif même pendant l'enregistrement : changer de micro en cours de
            // route est précisément ce qu'on veut pouvoir faire quand on
            // s'aperçoit que celui ouvert ne capte rien.
            Picker("Micro", selection: Binding(
                get: { controller.selectedInputUID },
                set: { controller.switchInput(to: $0) }
            )) {
                Text("Défaut système").tag(String?.none)
                ForEach(controller.inputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }

            if controller.selectedInputMissing {
                Label("Micro choisi débranché — le défaut système sera utilisé.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Capturer le son système", isOn: $controller.captureSystemAudio)
                .disabled(controller.isRecording)

            Divider()

            RecordButton(fullWidth: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            if controller.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.red)
                    Text(controller.elapsedString).monospacedDigit()
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let progress = controller.transcription {
                VStack(alignment: .leading, spacing: 4) {
                    if let overall = progress.overall {
                        ProgressView(value: overall)
                        Text("Transcription \(Int(overall * 100)) %").monospacedDigit()
                    } else if let modelFraction = progress.modelFraction, modelFraction > 0 {
                        ProgressView(value: modelFraction)
                        Text("Modèle de langue \(Int(modelFraction * 100)) %").monospacedDigit()
                    } else {
                        ProgressView()
                        Text("Installation du modèle de langue…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Derniers transcripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recents.isEmpty {
                    Text("Aucun transcript.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                } else {
                    // Liste plate : le regroupement par jour est réservé à la
                    // fenêtre, où la place ne manque pas.
                    ForEach(recents) { item in
                        RecentTranscriptRow(
                            item: item,
                            justCopied: justCopiedID == item.id,
                            onOpen: { openTranscripts(.detail(item.id)) },
                            onCopy: { copy(item) }
                        )
                    }
                }
            }

            Button {
                openTranscripts(.list)
            } label: {
                Label("Voir tous les transcripts", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            HStack {
                Spacer()
                Button("Quitter") { confirmQuit() }
            }
            .font(.caption)
        }
        .padding()
        .frame(width: 320)
        .onAppear(perform: reloadRecents)
        .onChange(of: controller.activity) { _, _ in reloadRecents() }
    }

    /// Même contenu que la copie depuis la fenêtre : titre puis corps.
    private func copy(_ item: TranscriptItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(item.displayName)\n\n\(item.bodyText)", forType: .string)
        justCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if justCopiedID == item.id { justCopiedID = nil }
        }
    }

    private func reloadRecents() {
        recents = TranscriptStore.list(limit: 10)
    }

    private func openTranscripts(_ request: TranscriptRequest) {
        selection.request = request
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "transcripts")
    }

    /// Demande confirmation avant de quitter (alerte modale, avec avertissement
    /// renforcé si un enregistrement est en cours).
    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Quitter Sillage ?"
        alert.informativeText = controller.isRecording
            ? "Un enregistrement est en cours — il sera interrompu et perdu."
            : "Voulez-vous vraiment quitter l'application ?"
        alert.alertStyle = controller.isRecording ? .warning : .informational
        alert.addButton(withTitle: "Quitter")
        alert.addButton(withTitle: "Annuler")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// Bouton d'enregistrement, partagé par le panneau de la barre de menus et la
/// fenêtre des transcripts.
struct RecordButton: View {
    @EnvironmentObject private var controller: RecordingController
    var fullWidth = false

    var body: some View {
        Button {
            controller.toggle()
        } label: {
            Label(controller.isRecording ? "Arrêter" : "Démarrer",
                  systemImage: controller.isRecording ? "stop.fill" : "record.circle")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isRecording ? .red : .accentColor)
    }
}

/// Un transcript récent dans le panneau : date et heure, libellé, et copie.
/// Deux boutons frères plutôt qu'imbriqués — un Button dans un Button ne
/// distingue pas les deux zones de clic.
private struct RecentTranscriptRow: View {
    let item: TranscriptItem
    let justCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text(item.shortDateTimeString)
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 92, alignment: .leading)
                    if item.hasCustomLabel {
                        Text(item.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Voir le transcript")

            RowIconButton(systemImage: justCopied ? "checkmark" : "doc.on.doc",
                          help: "Copier le transcript",
                          action: onCopy)
                .disabled(!item.hasText)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}
