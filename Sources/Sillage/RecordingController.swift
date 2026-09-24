import Foundation
import AVFoundation
import CoreAudio
import Combine

/// Phase en cours d'une session, pour que la fenêtre des transcripts puisse
/// distinguer « en cours » d'un échec au lieu de proposer les deux.
enum SessionPhase: Sendable {
    case recording
    case transcribing
}

struct SessionActivity: Sendable, Equatable {
    let dirName: String
    var phase: SessionPhase
}

/// Avancement d'une transcription. `fraction` est la position atteinte dans la
/// piste en cours — la seule mesure réelle dont on dispose.
struct TranscriptionProgress: Sendable, Equatable {
    var trackIndex: Int
    var trackCount: Int
    var trackLabel: String
    var fraction: Double?       // nil pendant l'installation du modèle
    var modelFraction: Double?  // avancement du téléchargement du modèle
    var startedAt: Date

    /// Avancement sur l'ensemble des pistes de la session.
    var overall: Double? {
        guard let fraction, trackCount > 0 else { return nil }
        return (Double(trackIndex) + fraction) / Double(trackCount)
    }

    /// Restant estimé d'après la vitesse observée. nil au démarrage, où
    /// l'extrapolation donnerait n'importe quoi.
    func remaining(now: Date) -> TimeInterval? {
        guard let overall, overall >= 0.05 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        return elapsed * (1 - overall) / overall
    }
}

@MainActor
final class RecordingController: ObservableObject {
    @Published var inputDevices: [AudioInputDevice] = []

    /// Micro choisi, identifié par son **UID** (stable) et non par son
    /// `AudioDeviceID`, que Core Audio réattribue à chaque branchement.
    /// `nil` = entrée par défaut du système.
    ///
    /// Persisté à dessein : sans ça, chaque relancement repartait sur le défaut
    /// système — qu'un casque Bluetooth accapare en se connectant, au point
    /// d'enregistrer un micro dans lequel l'utilisateur ne parle pas.
    @Published var selectedInputUID: String? =
        UserDefaults.standard.string(forKey: RecordingController.selectedInputKey) {
        didSet {
            UserDefaults.standard.set(selectedInputUID, forKey: Self.selectedInputKey)
            updateSelectionAvailability()
        }
    }
    private static let selectedInputKey = "selectedInputUID"

    /// Nom du micro réellement ouvert pendant l'enregistrement.
    @Published private(set) var activeInputName: String?
    /// Vrai quand le micro choisi n'est plus branché.
    @Published private(set) var selectedInputMissing = false
    @Published var captureSystemAudio: Bool = true
    @Published var isRecording: Bool = false
    @Published var statusMessage: String? = nil
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var activity: SessionActivity?
    /// Vrai tant que la tâche de transcription tourne, y compris après une
    /// annulation : l'analyseur peut mettre du temps à rendre la main.
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastTranscriptionError: String?
    @Published private(set) var transcription: TranscriptionProgress?
    /// Niveau crête du micro (0…1) pendant l'enregistrement, pour l'indicateur
    /// du panneau flottant.
    @Published private(set) var micLevel: Float = 0
    /// Vrai quand le micro n'a rien capté depuis assez longtemps pour que ce
    /// soit anormal : périphérique muet ou parole dans un autre micro.
    @Published private(set) var micSeemsSilent: Bool = false

    /// Verdict figé à l'arrêt, pour l'avertissement final.
    private var micHeardNothing = false
    /// Origine du compte à rebours « micro muet », repoussée à chaque bascule.
    private var micSilenceSince: TimeInterval = 0
    /// Dernière réouverture automatique, pour ne pas boucler sur une rafale.
    private var lastInputReopen = Date.distantPast

    private let recorder = SessionRecorder()
    private let floatingStop = FloatingStopController()
    private var timer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    private var startDate: Date?
    private(set) var sessionDir: URL?

    init() {
        refreshDevices()
        // Remplace le bouton « Rafraîchir » : la liste se met à jour toute seule.
        AudioDeviceManager.observeDeviceChanges { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Le micro choisi est-il toujours branché ? On préfère le signaler plutôt
    /// que de basculer en silence sur le défaut système.
    private func updateSelectionAvailability() {
        guard let uid = selectedInputUID else {
            selectedInputMissing = false
            return
        }
        selectedInputMissing = !inputDevices.contains { $0.uid == uid }
    }

    /// Traduit l'UID choisi en `AudioDeviceID`, au dernier moment : entre la
    /// sélection et le démarrage, le périphérique a pu changer d'identifiant.
    /// Renvoie aussi un avertissement à afficher si le micro a disparu.
    private func resolveInputDevice() -> (AudioDeviceID?, String?) {
        guard let uid = selectedInputUID else { return (nil, nil) }
        if let device = AudioDeviceManager.device(withUID: uid) { return (device.id, nil) }
        let name = inputDevices.first { $0.uid == uid }?.name ?? "Le micro choisi"
        Log.mic.error("Micro sélectionné introuvable (uid \(uid, privacy: .public)) → défaut système")
        return (nil, "« \(name) » est introuvable — enregistrement sur le micro par défaut.")
    }

    /// Le périphérique en cours a disparu ou s'est reconfiguré : on rouvre sur
    /// le même choix. Le trou est comblé par du silence, donc l'alignement avec
    /// la piste système tient. Débounce à 2 s : une reconfiguration arrive
    /// souvent en rafale (Bluetooth qui renégocie son profil).
    private func reopenInput() {
        guard isRecording, Date().timeIntervalSince(lastInputReopen) > 2 else { return }
        lastInputReopen = Date()
        Log.mic.notice("Entrée interrompue → réouverture du micro")
        switchInput(to: selectedInputUID)
    }

    /// Change de micro, y compris en pleine session : l'enregistrement continue
    /// dans le même fichier. C'est la porte de sortie quand on s'aperçoit en
    /// cours de route que le micro ouvert ne capte rien.
    func switchInput(to uid: String?) {
        selectedInputUID = uid
        guard isRecording else { return }
        // Reconstruire l'agrégat fait réagir le surveillant de périphérique :
        // sans armer le garde-fou ici, il relancerait aussitôt une bascule.
        lastInputReopen = Date()
        let (device, warning) = resolveInputDevice()
        do {
            try recorder.switchMic(to: device)
            activeInputName = recorder.micDeviceName
            micLevel = 0
            micSeemsSilent = false
            micSilenceSince = elapsed
            statusMessage = warning
        } catch {
            statusMessage = "Bascule micro impossible : \(error.localizedDescription)"
            Log.mic.error("Bascule micro impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshDevices() {
        inputDevices = AudioDeviceManager.inputDevices()
        updateSelectionAvailability()
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        do {
            let dir = try makeSessionDir()
            sessionDir = dir

            let (micDevice, deviceWarning) = resolveInputDevice()
            micLevel = 0
            micSeemsSilent = false
            micHeardNothing = false
            micSilenceSince = 0
            recorder.onLevel = { [weak self] level in
                Task { @MainActor in self?.micLevel = level }
            }
            recorder.onStreamInterrupted = { [weak self] in
                Task { @MainActor in self?.reopenInput() }
            }
            try recorder.start(micDevice: micDevice,
                               captureSystem: captureSystemAudio,
                               micURL: dir.appendingPathComponent("mic.wav"),
                               systemURL: dir.appendingPathComponent("system.wav"))
            activeInputName = recorder.micDeviceName

            startDate = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                    // Au bout de 12 s sans le moindre signal, ce n'est plus un
                    // blanc dans la conversation : le micro ne capte rien.
                    self.micSeemsSilent = !self.recorder.didHearSignal
                        && (self.elapsed - self.micSilenceSince) >= 12
                }
            }

            isRecording = true
            activity = SessionActivity(dirName: dir.lastPathComponent, phase: .recording)
            // Le chrono du panneau dit déjà que ça tourne : on garde ce slot
            // libre pour les vrais avertissements (micro introuvable, son
            // système indisponible…).
            statusMessage = deviceWarning
            floatingStop.show(controller: self)
        } catch {
            statusMessage = "Erreur au démarrage : \(error.localizedDescription)"
        }
    }

    func stop() {
        floatingStop.hide()
        timer?.invalidate()
        timer = nil
        recorder.stop()
        // Lus après l'arrêt de l'IOProc : les verdicts ne bougeront plus.
        micHeardNothing = !recorder.didHearSignal
        let systemHeardNothing = recorder.systemHeardNothing
        recorder.onLevel = nil
        recorder.onStreamInterrupted = nil
        micLevel = 0
        micSeemsSilent = false
        activeInputName = nil
        if micHeardNothing {
            Log.mic.error("Piste micro muette : aucun signal capté de toute la session")
        }

        isRecording = false
        let dir = sessionDir
        // Figés maintenant : les WAV seront supprimés, la durée ne serait plus retrouvable.
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? elapsed
        let systemRequested = captureSystemAudio
        startDate = nil
        activity?.phase = .transcribing

        statusMessage = "Transcription en cours…"
        isTranscribing = true
        transcriptionTask = Task {
            let capturedNothing = systemRequested && systemHeardNothing
            if capturedNothing {
                self.statusMessage = "Aucun son système capté — seule la piste micro sera transcrite."
            }
            await self.transcribeSession(dir: dir,
                                         duration: duration,
                                         systemRequested: systemRequested,
                                         systemCapturedNothing: capturedNothing)
            self.isTranscribing = false
        }
    }

    /// Abandonne la transcription en cours. Libère l'interface tout de suite ;
    /// la tâche, elle, peut mettre du temps à s'arrêter — `isTranscribing` reste
    /// vrai jusque-là pour qu'une relance ne s'exécute pas par-dessus.
    func cancelTranscription() {
        guard let task = transcriptionTask else { return }
        task.cancel()
        transcriptionTask = nil
        activity = nil
        transcription = nil
        statusMessage = "Transcription annulée — l'audio est conservé."
        Log.app.notice("Transcription annulée par l'utilisateur")
    }

    /// Relance la transcription d'un enregistrement dont l'audio a survécu à un
    /// échec précédent. Sans effet si une transcription tourne encore.
    func retryTranscription(at dir: URL) {
        guard activity == nil, !isTranscribing else { return }

        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        // L'audio étant là, sa durée réelle vaut mieux qu'une estimation.
        let duration = audioDuration(of: micURL) ?? audioDuration(of: sysURL) ?? 0
        let systemRequested = FileManager.default.fileExists(atPath: sysURL.path)
        // Un tap muet laisse un system.wav réduit à son en-tête : 0 frame.
        let capturedNothing = systemRequested && (audioDuration(of: sysURL) ?? 0) <= 0

        activity = SessionActivity(dirName: dir.lastPathComponent, phase: .transcribing)
        statusMessage = "Transcription en cours…"
        isTranscribing = true
        transcriptionTask = Task {
            await self.transcribeSession(dir: dir,
                                         duration: duration,
                                         systemRequested: systemRequested,
                                         systemCapturedNothing: capturedNothing)
            self.isTranscribing = false
        }
    }

    private func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Transcrit une piste en publiant son avancement.
    private func transcribeTrack(_ url: URL,
                                 label: String,
                                 index: Int,
                                 of count: Int,
                                 startedAt: Date,
                                 locale: Locale) async throws -> [TranscriptSegment] {
        transcription = TranscriptionProgress(trackIndex: index,
                                              trackCount: count,
                                              trackLabel: label,
                                              fraction: 0,
                                              modelFraction: nil,
                                              startedAt: startedAt)

        return try await Transcriber.transcribe(fileURL: url, locale: locale) { [weak self] stage in
            Task { @MainActor in
                guard var progress = self?.transcription else { return }
                switch stage {
                case .installingModel(let modelFraction):
                    progress.fraction = nil
                    progress.modelFraction = modelFraction
                case .analyzing(let fraction):
                    progress.fraction = fraction
                    progress.modelFraction = nil
                }
                self?.transcription = progress
            }
        }
    }

    /// Transcrit les deux pistes de la session, écrit transcript.md et meta.json,
    /// puis supprime l'audio (uniquement en cas de succès).
    private func transcribeSession(dir: URL?,
                                   duration: TimeInterval,
                                   systemRequested: Bool,
                                   systemCapturedNothing: Bool) async {
        defer {
            activity = nil
            transcription = nil
        }
        guard let dir else { return }
        lastTranscriptionError = nil
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        let locale = Locale(identifier: "fr-FR")
        let fm = FileManager.default

        do {
            var mic: [TranscriptSegment] = []
            var system: [TranscriptSegment] = []

            let hasMicTrack = fm.fileExists(atPath: micURL.path)
            let hasSystemTrack = fm.fileExists(atPath: sysURL.path)
            // Les deux pistes se partagent la barre d'avancement.
            let trackCount = (hasMicTrack ? 1 : 0) + (hasSystemTrack ? 1 : 0)
            let startedAt = Date()
            var trackIndex = 0

            if hasMicTrack {
                mic = try await transcribeTrack(micURL, label: "micro",
                                                index: trackIndex, of: trackCount,
                                                startedAt: startedAt, locale: locale)
                trackIndex += 1
            }
            if hasSystemTrack {
                system = try await transcribeTrack(sysURL, label: "son système",
                                                   index: trackIndex, of: trackCount,
                                                   startedAt: startedAt, locale: locale)
            }

            // L'analyseur peut ignorer l'annulation et rendre un résultat : sans
            // ce contrôle, on supprimerait l'audio qu'on vient de promettre.
            try Task.checkCancellation()

            let markdown = Transcriber.mergeToMarkdown(mic: mic, system: system, date: Date())
            let outURL = dir.appendingPathComponent("transcript.md")
            try markdown.write(to: outURL, atomically: true, encoding: .utf8)

            // Une piste système réduite à son en-tête existe sans rien contenir :
            // c'est « capture indisponible », pas « aucune parole détectée ».
            TranscriptStore.saveMeta(
                SessionMeta(duration: duration,
                            systemRequested: systemRequested,
                            systemTranscribed: hasSystemTrack && !systemCapturedNothing,
                            micSegments: mic.count,
                            systemSegments: system.count),
                in: dir)

            let count = mic.count + system.count
            Log.app.notice("Transcript écrit : \(outURL.path, privacy: .public) (\(count) segments)")

            // Contrainte projet : l'audio est supprimé une fois le transcript
            // réalisé (uniquement en cas de succès, pour ne pas perdre l'audio
            // si la transcription échoue).
            deleteAudio(at: [micURL, sysURL])
            let systemNote = systemCapturedNothing ? " · son système non capté" : ""
            let micNote = micHeardNothing
                ? " · ⚠️ micro muet : vérifie le périphérique sélectionné"
                : ""
            statusMessage = "Transcript prêt (\(count) segments) · audio supprimé\(systemNote)\(micNote)"
        } catch {
            // Une annulation volontaire n'est pas un échec : ni meta, ni erreur,
            // l'audio reste sur le disque. Toutes les erreurs remontées après
            // annulation ne sont pas des CancellationError : le drapeau fait foi.
            guard !Task.isCancelled else {
                Log.app.notice("Transcription abandonnée : \(dir.lastPathComponent, privacy: .public)")
                return
            }
            TranscriptStore.saveMeta(
                SessionMeta(duration: duration,
                            systemRequested: systemRequested,
                            systemTranscribed: false,
                            micSegments: 0,
                            systemSegments: 0),
                in: dir)
            lastTranscriptionError = error.localizedDescription
            statusMessage = "Échec transcription : \(error.localizedDescription)"
            Log.app.error("Échec transcription : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Supprime les fichiers audio de la session (le transcript est conservé).
    private func deleteAudio(at urls: [URL]) {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                Log.app.notice("Audio supprimé : \(url.lastPathComponent, privacy: .public)")
            } catch {
                Log.app.error("Échec suppression audio \(url.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeSessionDir() throws -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sillage/Recordings", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
