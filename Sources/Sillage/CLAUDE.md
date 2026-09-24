# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Le projet

**Sillage** — app macOS de barre de menus qui enregistre le micro choisi + le son
système, produit un `transcript.md` horodaté 100 % on-device, puis supprime l'audio.
Sans réseau, sans dépendance externe (contrainte volontaire : voir CONTRIBUTING.md).

Le dossier du dépôt s'appelle encore `MyGranola` (nom d'origine) — le produit, le
bundle ID (`com.cletetour.sillage`) et la cible SwiftPM s'appellent **Sillage**.
`build/MyGranola.app` est un résidu ignoré par git.

## Commandes

```bash
./build.sh                 # swift build -c release + assemblage du bundle + signature
open build/Sillage.app
swift build                # compilation seule (debug), utile pour un check rapide

# logs (indispensable : l'app est un agent sans console)
log stream --predicate 'subsystem == "com.cletetour.sillage"'
log show --last 10m --predicate 'subsystem == "com.cletetour.sillage"'

killall Sillage
```

**Pas de suite de tests** et pas de CI (les runners macOS 26 n'existent pas encore
chez GitHub Actions). La validation est manuelle : lancer, enregistrer en parlant
au micro *et* avec un son système, arrêter, puis vérifier dans « Voir les
transcripts » que le `transcript.md` est cohérent (les deux locuteurs, timecodes
alignés) et que `mic.wav`/`system.wav` ont disparu.

Prérequis : macOS 26 + SDK macOS 26 (`xcrun --sdk macosx --show-sdk-version` → `26.x`),
Apple Silicon. `Package.swift` épingle `.macOS("26.0")` et le **mode langage Swift 5**
(délibéré : évite le bruit de concurrence stricte sur les callbacks Core Audio).

## Signature & permissions TCC

`build.sh` signe avec `$SILLAGE_SIGN_ID`, sinon la 1re identité valide du trousseau,
sinon en ad-hoc. **Avec une signature ad-hoc, macOS redemande micro + son système
à chaque rebuild** — si les permissions se comportent bizarrement pendant un debug,
vérifier d'abord quelle identité a servi. Pour repartir de zéro :
`tccutil reset Microphone com.cletetour.sillage` (idem `AudioCapture`).

`Resources/Info.plist` et `Resources/Sillage.entitlements` sont copiés tels quels
dans le bundle : toute nouvelle permission se déclare là, pas dans `Package.swift`.
L'app n'est **pas sandboxée** (écriture dans Application Support + process taps).
`LSUIElement` = pas d'icône Dock.

## Architecture

Pipeline d'une session, orchestré par `RecordingController` (le seul
`ObservableObject`, `@MainActor`, injecté en `environmentObject`) :

```
                      ┌─► mic.wav    ┐
SessionRecorder ──────┤              ├─► Transcriber.transcribe (×2) ─► mergeToMarkdown ─► transcript.md
(1 seul IOProc)       └─► system.wav ┘                                  puis suppression des WAV
```

Une session = un dossier `~/Library/Application Support/Sillage/Recordings/<ISO8601>/`.

### Les invariants à ne pas casser

**La séparation des locuteurs vient uniquement de la piste** (`mic` → « Moi »,
`system` → « Interlocuteur »). Il n'y a aucune diarisation. Fusionner les deux
pistes en un seul fichier détruirait la fonctionnalité.

**L'horodatage de `mic.wav` et `system.wav` doit rester comparable**, puisque
`mergeToMarkdown` trie les segments des deux pistes sur un même axe de temps.
C'est garanti par construction : les deux pistes sortent du **même IOProc**, donc
de la même horloge (le micro, source d'horloge de l'agrégat). Séparer à nouveau
les deux captures en deux devices ramènerait la dérive — et la reconstruction de
timeline à coups de `mach_absolute_time()` qu'on a pu supprimer.

**L'audio n'est supprimé qu'en cas de succès de la transcription**
(`RecordingController.transcribeSession`) — un échec conserve les WAV pour ne pas
perdre l'enregistrement.

**Le nom de dossier de session est un format de date partagé** :
`makeSessionDir` écrit de l'ISO8601 avec `:` → `-`, et `TranscriptStore.parser`
le relit avec `yyyy-MM-dd'T'HH-mm-ss'Z'`. Le tri de la liste repose sur l'ordre
lexicographique de ces noms. Changer l'un impose de changer l'autre.

### Pièges Core Audio (appris à la dure — les commentaires du code les documentent)

- **`AVAudioEngine` a été abandonné** pour la capture : forcer un device d'entrée
  précis y est fragile (aucun buffer, ou échec `-10868`). `SessionRecorder` lit le
  device en Core Audio via `AudioDeviceCreateIOProcIDWithBlock`.
- **Le micro se lit via l'agrégat, jamais en second client direct.** Depuis
  macOS 26.6, un second client direct d'un périphérique d'entrée déjà ouvert par
  une app de visio ne reçoit que des **zéros** : la session entière enregistrait
  du silence, sans erreur ni trace. Le micro placé en sous-device de l'agrégat
  (et source d'horloge) contourne ce mutage — et fournit au passage les deux
  pistes dans un seul buffer. NB : coreaudiod continue de loguer
  `hasNonTapInputStream == false` ; c'est bénin, ce n'était pas la cause.
- **`kAudioDevicePropertyStreamFormat` ne décrit que le premier flux** : sur
  l'agrégat il annonce 1 canal là où il en arrive 3. Toujours lire la disposition
  via `kAudioDevicePropertyStreamConfiguration`
  (`AudioDeviceManager.inputChannelsPerBuffer`).
- **Le fichier doit adopter le format réel de la source**, entrelacement compris,
  sinon `AVAudioFile.write` échoue en `-50`. On n'impose jamais un format cible.
- **Barrette de micros (> 2 canaux, ex. micro intégré MacBook)** :
  les canaux arrivent entrelacés dans le buffer du sous-device ; on construit le
  format depuis le nombre de canaux lu dans la configuration, sans passer par
  `AVAudioFormat(streamDescription:)` (qui renvoie `nil` au-delà de 2 canaux sans
  layout).
- **Son système = Core Audio process taps**, pas ScreenCaptureKit : un tap global
  privé (`CATapDescription`) inséré dans l'agrégat privé, aux côtés du micro. C'est
  ce qui permet la permission « sons du système uniquement » sans permission d'écran.
- **`kAudioAggregateDeviceTapAutoStartKey` doit être à `false`** dans notre
  composition (micro = source d'horloge + tap). À `true`, l'IO attend que le tap
  démarre, donc qu'une app joue du son : une session lancée dans le silence ne
  captait rien, micro compris. Les exemples d'Apple et de la communauté le
  mettent à `true`, mais pour un agrégat tap-only.
- **L'agrégat tourne à la fréquence du micro** (sa source d'horloge) : un micro
  Bluetooth à 16 kHz ramène donc aussi la piste système à 16 kHz.
- `cleanup()` doit détruire tap **et** device agrégé : ce sont des objets globaux
  du système audio, une fuite les laisse en place après la fin du process.

### Transcription

`Transcriber` utilise `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26), en `fr-FR`
résolu via `supportedLocale(equivalentTo:)`, et installe le modèle de langue à la
demande (`AssetInventory`) — le tout premier lancement peut donc être long. Les
résultats sont consommés dans une `Task` concurrente *pendant* `analyzeSequence`,
puis `finalizeAndFinishThroughEndOfInput()` clôt le flux : inverser cet ordre
bloque.

### Interface

- `SillageApp` : `MenuBarExtra` (style `.window`) + une `Window` `id: "transcripts"`.
- `ContentView` : le panneau de la barre de menus (choix du micro, toggle son
  système, start/stop, confirmation de quit via `NSAlert`).
- `FloatingStopController` / `FloatingStopView` : `NSPanel` borderless
  non-activant, niveau `.statusBar`, `canJoinAllSpaces` — reste visible au-dessus
  de tout pendant l'enregistrement, avec `glassEffect` (Liquid Glass, macOS 26).
- `TranscriptStore` (I/O disque : liste, label dans `label.txt`, suppression) est
  volontairement séparé de `TranscriptsView` (présentation).

## Conventions

- Commentaires et chaînes UI **en français**. Les commentaires expliquent *pourquoi*
  (surtout les contournements Core Audio) — les conserver lors d'un refactor.
- **NB** : Eviter les commentaires à chaque ligne, privilégier des commentaires concis sur fonction ou classe (qui ne reprenne pas les infos déjà porté par le code lui même)
- Journalisation via `Log.app` / `Log.mic` / `Log.system` (`Log.swift`), jamais
  `print`. Les valeurs interpolées portent `privacy: .public` pour rester lisibles
  dans `log show`.
- Erreurs Core Audio : helpers `fail(_:_:)` locaux qui loguent et emballent l'`OSStatus`.
- Aucune dépendance externe sans discussion préalable.
- PR multi-sujets acceptée, à condition d'un commit par sujet (voir CONTRIBUTING.md).

## Limite connue

Sur haut-parleurs, le micro capte le son système → le même passage apparaît dans
les deux pistes. Aucune annulation d'écho n'est implémentée ; tester au casque.
