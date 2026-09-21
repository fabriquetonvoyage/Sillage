import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Capture d'une session : micro (« moi ») et son système (« eux »), dans **un
/// seul** IOProc Core Audio.
///
/// Les deux sources sont réunies dans un unique device agrégé — le micro comme
/// sous-device et source d'horloge, le son système comme sous-tap. C'est la
/// composition prévue par Apple (`subdevices` + `taps` + `master`), et elle
/// résout trois problèmes d'un coup :
///
///  1. **Le micro muet.** Depuis macOS 26.6, un **second client direct** d'un
///     périphérique d'entrée déjà ouvert par une app de visio ne reçoit que des
///     zéros — le micro enregistrait du silence pendant toute une réunion, sans
///     erreur ni trace. Lire le micro **à travers l'agrégat** contourne ce
///     mutage (vérifié en A/B : trois clients simultanés captent sans problème).
///  2. **L'alignement.** Les deux pistes sortent du même buffer, cadencées par
///     la même horloge : plus de reconstruction de timeline ni de silence à
///     combler, et le tap livre des zéros pendant les silences au lieu de ne
///     rien livrer du tout.
///  3. **La simplicité.** Un device, un IOProc, un cycle de vie.
///
/// Conséquence à connaître : l'agrégat tourne à la fréquence du micro, qui est
/// sa source d'horloge. Un micro Bluetooth à 16 kHz ramène donc aussi la piste
/// système à 16 kHz.
final class SessionRecorder {

    // MARK: - État Core Audio

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioDevice = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.cletetour.sillage.session-io")

    // MARK: - Pistes

    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    /// Format livré par l'IOProc pour chaque piste (canaux entrelacés).
    private var micLiveFormat: AVAudioFormat?
    /// Format du micro après réduction des canaux (mono pour une barrette).
    private var micStageFormat: AVAudioFormat?
    private var systemLiveFormat: AVAudioFormat?
    /// Format des fichiers, figé au démarrage : un WAV n'en change pas en cours
    /// de route. Après une bascule de micro, on convertit vers lui.
    private var micFileFormat: AVAudioFormat?
    private var systemFileFormat: AVAudioFormat?
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?

    private var micURL: URL?
    private var systemURL: URL?
    private var wantsSystem = false

    // MARK: - Contrat avec l'interface

    /// Appelé quand le device de capture disparaît ou se reconfigure.
    var onStreamInterrupted: (() -> Void)?
    /// Vrai si le tap n'a jamais rien livré d'autre que du silence.
    private(set) var systemHeardNothing = true
    private(set) var micDeviceName: String?

    private var firstSampleLogged = false
    /// -40 dBFS : la parole dépasse largement, un flux mort jamais.
    private static let signalThreshold: Float = 0.01

    private var listener: AudioObjectPropertyListenerBlock?
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    // MARK: - Cycle de vie

    func start(micDevice chosen: AudioDeviceID?,
               captureSystem: Bool,
               micURL: URL,
               systemURL: URL) throws {
systemHeardNothing = true
        firstSampleLogged = false
        micConverter = nil
        systemConverter = nil
        self.micURL = micURL
        self.systemURL = systemURL
        self.wantsSystem = captureSystem

        let mic = try resolveMic(chosen)
        try openIO(mic: mic, captureSystem: captureSystem)

        // Les fichiers adoptent le format réellement livré.
        micFileFormat = micStageFormat
        systemFileFormat = systemLiveFormat
        if let fmt = micFileFormat {
            micFile = try AVAudioFile(forWriting: micURL, settings: fmt.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        }
        if let fmt = systemFileFormat {
            systemFile = try AVAudioFile(forWriting: systemURL, settings: fmt.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        }

        try startIO()
        Log.mic.notice("Session démarrée : micro « \(self.micDeviceName ?? "?", privacy: .public) » \(self.micLiveFormat?.channelCount ?? 0, privacy: .public) ch, système \(self.systemLiveFormat == nil ? "désactivé" : "activé", privacy: .public), \(Int(self.micLiveFormat?.sampleRate ?? 0), privacy: .public) Hz")
    }

    /// Change de micro sans interrompre la session. L'agrégat étant bâti autour
    /// du micro, il faut le reconstruire ; les fichiers, eux, restent ouverts et
    /// gardent leur format (conversion si le nouveau périphérique diffère).
    func switchMic(to chosen: AudioDeviceID?) throws {
        let previous = (device: ioDevice, mic: micDeviceName)
        stopIO()
        destroyAggregateAndTap()
        do {
            let mic = try resolveMic(chosen)
            try openIO(mic: mic, captureSystem: wantsSystem)
            micConverter = try converter(from: micStageFormat, to: micFileFormat, label: "micro")
            systemConverter = try converter(from: systemLiveFormat, to: systemFileFormat, label: "système")
            try startIO()
            Log.mic.notice("Micro basculé sur « \(self.micDeviceName ?? "?", privacy: .public) »")
        } catch {
            Log.mic.error("Bascule impossible (\(error.localizedDescription, privacy: .public)) — micro précédent « \(previous.mic ?? "?", privacy: .public) » perdu")
            throw error
        }
    }

    func stop() {
        cleanup()
        Log.mic.notice("Session arrêtée")
    }

    // MARK: - Ouverture

    private func resolveMic(_ chosen: AudioDeviceID?) throws -> AudioDeviceID {
        let dev = (chosen != nil && chosen != AudioObjectID(kAudioObjectUnknown))
            ? chosen!
            : (Self.defaultInputDevice() ?? AudioObjectID(kAudioObjectUnknown))
        guard dev != AudioObjectID(kAudioObjectUnknown) else {
            throw fail("Aucun périphérique d'entrée", -1)
        }
        micDeviceName = AudioDeviceManager.name(of: dev) ?? "device \(dev)"
        return dev
    }

    /// Construit le device sur lequel on lira : l'agrégat micro + tap si le son
    /// système est demandé, sinon le micro seul.
    private func openIO(mic: AudioDeviceID, captureSystem: Bool) throws {
        if captureSystem, let micUID = AudioDeviceManager.uid(of: mic) {
            try createTap()
            ioDevice = try createAggregate(micUID: micUID)
        } else {
            if captureSystem {
                Log.system.error("UID du micro introuvable — session sans son système")
            }
            ioDevice = mic
        }

        // `StreamConfiguration` fait foi : `StreamFormat` ne décrit que le
        // premier flux et annoncerait 1 canal là où il en arrive 3.
        let layout = AudioDeviceManager.inputChannelsPerBuffer(ioDevice)
        guard let micChannels = layout.first, micChannels > 0 else {
            throw fail("Aucun canal d'entrée sur le device de capture", -1)
        }
        let rate = Self.nominalSampleRate(ioDevice)
        guard rate > 0 else { throw fail("Fréquence d'échantillonnage illisible", -1) }

        guard let live = Self.format(channels: micChannels, rate: rate) else {
            throw fail("Format micro inexploitable (\(micChannels) canaux, \(Int(rate)) Hz)")
        }
        micLiveFormat = live
        // Une barrette de micros donnerait un WAV multicanal inutile à la
        // transcription : on n'en garde qu'un capteur.
        micStageFormat = micChannels > 2 ? Self.monoFormat(rate: rate) : live
        guard micStageFormat != nil else { throw fail("Réduction mono impossible", -1) }
        systemLiveFormat = layout.count > 1 ? Self.format(channels: layout[1], rate: rate) : nil
    }

    private func createTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Sillage"
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw fail("AudioHardwareCreateProcessTap", status)
        }
        tapID = tap
        tapUUID = desc.uuid.uuidString
    }
    private var tapUUID = ""

    private func createAggregate(micUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sillage Session",
            kAudioAggregateDeviceUIDKey: "com.cletetour.sillage.agg.\(tapUUID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // Le micro donne l'horloge : c'est lui qui cadence l'IOProc, donc le
            // tap livre des zéros pendant les silences au lieu de se taire.
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard status == noErr, agg != AudioObjectID(kAudioObjectUnknown) else {
            throw fail("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = agg
        return agg
    }

    private func startIO() throws {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, ioDevice, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.receive(inInputData)
        }
        guard status == noErr, let procID else {
            throw fail("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = procID
        status = AudioDeviceStart(ioDevice, procID)
        guard status == noErr else { throw fail("AudioDeviceStart", status) }
        watch(ioDevice)
    }

    private func stopIO() {
        unwatch()
        guard ioDevice != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID else { return }
        AudioDeviceStop(ioDevice, procID)
        AudioDeviceDestroyIOProcID(ioDevice, procID)
        ioProcID = nil
    }

    private func destroyAggregateAndTap() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ioDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func cleanup() {
        stopIO()
        destroyAggregateAndTap()
        micFile = nil
        systemFile = nil
        micLiveFormat = nil
        micStageFormat = nil
        systemLiveFormat = nil
        micFileFormat = nil
        systemFileFormat = nil
        micConverter = nil
        systemConverter = nil
    }

    // MARK: - Réception

    /// Un seul buffer list pour les deux pistes : buffer 0 = micro (sous-device),
    /// buffer 1 = son système (sous-tap).
    private func receive(_ data: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: data))
        guard buffers.count > 0 else { return }

        if let live = micLiveFormat, let stage = micStageFormat, let target = micFileFormat {
            write(buffers[0], live: live, stage: stage, target: target,
                  converter: micConverter, file: micFile, isMic: true)
        }
        if buffers.count > 1, let live = systemLiveFormat, let target = systemFileFormat {
            write(buffers[1], live: live, stage: live, target: target,
                  converter: systemConverter, file: systemFile, isMic: false)
        }
    }

    private func write(_ buffer: AudioBuffer,
                       live: AVAudioFormat,
                       stage: AVAudioFormat,
                       target: AVAudioFormat,
                       converter: AVAudioConverter?,
                       file: AVAudioFile?,
                       isMic: Bool) {
        guard let file, buffer.mDataByteSize > 0 else { return }
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        withUnsafePointer(to: &abl) { ptr in
            guard let raw = AVAudioPCMBuffer(pcmFormat: live, bufferListNoCopy: ptr),
                  raw.frameLength > 0 else { return }
            let source = stage === live ? raw : Self.firstChannel(of: raw, as: stage)
            guard let source else { return }
            let out = converter.flatMap { Self.convert(source, with: $0, to: target) } ?? source
            if !isMic, Self.peak(of: out) > Self.signalThreshold {
                systemHeardNothing = false
            }
            do {
                if !firstSampleLogged {
                    firstSampleLogged = true
                    Log.mic.notice("Premiers échantillons reçus → écriture OK")
                }
                try file.write(from: out)
            } catch {
                Log.mic.error("Erreur d'écriture : \(error.localizedDescription, privacy: .public)")
            }
        }
    }


    // MARK: - Surveillance du device

    private func watch(_ dev: AudioObjectID) {
        unwatch()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let handler = self.onStreamInterrupted else { return }
            DispatchQueue.main.async { handler() }
        }
        for (selector, scope) in Self.watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(dev, &address, DispatchQueue.main, block)
        }
        listener = block
        watchedDevice = dev
    }

    private func unwatch() {
        guard let block = listener, watchedDevice != AudioObjectID(kAudioObjectUnknown) else { return }
        for (selector, scope) in Self.watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, DispatchQueue.main, block)
        }
        listener = nil
        watchedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Helpers

    private func converter(from live: AVAudioFormat?, to target: AVAudioFormat?,
                           label: String) throws -> AVAudioConverter? {
        guard let live, let target else { return nil }
        guard live != target else { return nil }
        guard let conv = AVAudioConverter(from: live, to: target) else {
            throw fail("Conversion \(label) impossible (\(Int(live.sampleRate)) Hz \(live.channelCount) ch → \(Int(target.sampleRate)) Hz \(target.channelCount) ch)")
        }
        return conv
    }

    private static func convert(_ source: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error {
            Log.mic.error("Conversion échouée : \(error?.localizedDescription ?? "?", privacy: .public)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(channels[0], buffer.stride, &peak, vDSP_Length(buffer.frameLength))
        return peak
    }

    /// Float32 entrelacé : c'est ainsi que l'IOProc livre chaque buffer.
    /// Au-delà de 2 canaux (barrette du micro intégré), `AVAudioFormat` exige un
    /// layout explicite — sans lui il renvoie `nil`, quelle que soit la porte
    /// d'entrée utilisée.
    private static func format(channels: Int, rate: Double) -> AVAudioFormat? {
        guard channels > 0 else { return nil }
        guard channels > 2 else {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                 channels: AVAudioChannelCount(channels), interleaved: true)
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
    }

    private static func monoFormat(rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                      channels: 1, interleaved: false)
    }

    /// Extrait le premier canal d'une barrette de micros. Moyenner des capsules
    /// espacées de plusieurs centimètres créerait un filtrage en peigne dans la
    /// voix ; un seul capteur reste propre.
    private static func firstChannel(of source: AVAudioPCMBuffer,
                                     as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard frames > 0,
              let input = source.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: source.frameLength),
              let output = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = source.frameLength
        let step = source.stride
        let channel = input[0]
        for i in 0..<frames { output[i] = channel[i * step] }
        return out
    }

    private static func nominalSampleRate(_ dev: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev)
        return status == noErr ? dev : nil
    }

    private func fail(_ message: String) -> NSError {
        Log.mic.error("\(message, privacy: .public)")
        return NSError(domain: "Sillage.Session", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fail(_ what: String, _ status: OSStatus) -> NSError {
        Log.mic.error("\(what, privacy: .public) a échoué (status \(status, privacy: .public))")
        return NSError(domain: "Sillage.Session", code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "\(what) a échoué (status \(status))"])
    }
}
