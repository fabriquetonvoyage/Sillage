# Sillage

Application macOS locale (barre de menus) de prise de notes de réunion : elle
écoute le **micro de ton choix** et le **son du système**, produit un **transcript
horodaté** entièrement **on-device** (aucune donnée ne quitte ta machine), puis
supprime automatiquement l'audio.

Développée **sans Xcode.app** : tout se compile en ligne de commande avec les
Command Line Tools.

> ⚠️ **Consentement** : enregistrer une conversation sans en informer les
> participants est illégal dans de nombreux pays (en France, art. 226-1 du Code
> pénal). Préviens toujours tes interlocuteurs.

## Fonctionnalités

- 🎙️ **Capture double piste** : ton micro (périphérique au choix : intégré,
  casque Bluetooth, interface…) sur une piste, le son système sur une autre.
- 🗣️ **Séparation des locuteurs gratuite** : « Moi » (micro) vs « Interlocuteur »
  (son système), grâce aux deux pistes distinctes.
- 📝 **Transcription on-device** via `SpeechAnalyzer` / `SpeechTranscriber`
  (macOS 26), en français, horodatée.
- 🔊 **Son système sans capture d'écran** : via les *Core Audio process taps*
  (permission « enregistrement des sons du système uniquement »), pas de
  permission d'enregistrement d'écran.
- ⏱️ **Pistes alignées** : les silences sont reconstruits pour que les deux
  pistes restent synchronisées (pas de décalage dans le transcript).
- 🗑️ **Confidentialité** : l'audio (`mic.wav` / `system.wav`) est **supprimé
  automatiquement** une fois le transcript généré.
- 🪟 **Fenêtre des transcripts** : liste groupée par jour (Aujourd'hui / Hier /
  JJ/MM) avec durée de chaque enregistrement, lecture du transcript dans la même
  fenêtre, libellé éditable, copie, suppression, ouverture du dossier.
- 📊 **Avancement de la transcription** : barre, pourcentage et temps restant
  estimé, déduits de la position des segments dans l'audio. Annulable.
- ♻️ **Relance** : si la transcription échoue, l'audio est conservé et un bouton
  permet de la relancer.
- 🕘 **Accès rapide** : les 10 derniers transcripts directement dans le panneau
  de la barre de menus, avec copie en un clic.
- 🔴 **Panneau flottant** *Liquid Glass* avec bouton Stop, toujours visible
  pendant l'enregistrement, avec **jauge de niveau** et le nom du micro
  réellement ouvert — et une alerte si la piste reste muette.
- 🔁 **Changement de micro en cours d'enregistrement**, sans interrompre la
  session.
- ⚠️ **Confirmation** avant de quitter l'application.

## Prérequis

- **macOS 26 (Tahoe) ou plus**, sur **Apple Silicon**.
- Pour compiler : **Command Line Tools for Xcode 26** (SDK macOS 26).
  - Vérifier : `xcrun --sdk macosx --show-sdk-version` → doit afficher `26.x`.

## Installation

### Option A — Télécharger l'app (le plus simple)

1. Va dans [**Releases**](../../releases) et télécharge `Sillage-vX.Y.Z.zip`.
2. Décompresse, puis déplace `Sillage.app` dans `/Applications`.
3. L'app n'étant pas notarisée par Apple, macOS la bloque au premier lancement.
   Lève la mise en quarantaine :
   ```bash
   xattr -dr com.apple.quarantine /Applications/Sillage.app
   ```
   (ou : clic droit sur l'app → **Ouvrir**, puis confirme ; ou *Réglages
   Système › Confidentialité et sécurité › Ouvrir quand même*.)

### Option B — Compiler depuis les sources

```bash
git clone https://github.com/fabriquetonvoyage/Sillage.git
cd Sillage
./build.sh
open build/Sillage.app
```

`build.sh` compile via SwiftPM, assemble le bundle `.app`, et le signe
(automatiquement avec la première identité de signature valide du trousseau,
sinon en ad-hoc).

## Utilisation

1. Lance l'app → une icône **●** apparaît dans la barre de menus. Le panneau
   liste les 10 derniers transcripts ; un clic ouvre l'un d'eux.
2. Choisis la **source micro**, active/désactive **Capturer le son système**.
3. **Démarrer** → un panneau flottant affiche le chrono et un bouton Stop.
4. **Arrêter** → la transcription démarre en affichant son avancement. L'audio
   est supprimé dès que le transcript est écrit, et celui-ci apparaît dans
   **Voir tous les transcripts**.

Chaque session est un dossier
`~/Library/Application Support/Sillage/Recordings/<horodatage ISO 8601>/`
contenant le `transcript.md`, un `meta.json` (durée mesurée, état des deux
pistes) et un `label.txt` si tu as nommé la session.

## Permissions demandées

- **Micro** : pour enregistrer ta voix.
- **Enregistrement des sons du système uniquement** : pour capter l'audio des
  autres apps (visio, vidéos…). Aucune capture d'écran.

## Confidentialité

Capture et transcription sont **100 % locales** : ton audio et ton texte ne
quittent jamais la machine, et Sillage n'ouvre aucune connexion. Seule exception,
sans rapport avec tes données : au premier usage, **macOS** peut télécharger
lui-même le modèle de langue français s'il n'est pas déjà installé.

Les fichiers audio sont supprimés dès que le transcript est produit — **sauf si
la transcription échoue**, auquel cas ils sont conservés pour permettre une
relance, et supprimés à sa réussite.

## Architecture

| Fichier | Rôle |
|---|---|
| `SillageApp.swift` | Point d'entrée SwiftUI, icône barre de menus, fenêtre transcripts |
| `ContentView.swift` | Panneau : micro, son système, Démarrer/Arrêter, derniers transcripts |
| `RecordingController.swift` | Orchestration start/stop, sessions, avancement, relance, suppression audio |
| `AudioDeviceManager.swift` | Énumération Core Audio des entrées, observation des branchements |
| `MicRecorder.swift` | Capture micro (IOProc Core Audio) → `mic.wav` |
| `SystemAudioRecorder.swift` | Capture son système (process tap + device agrégé) → `system.wav` |
| `Transcriber.swift` | Modèle de langue, transcription `SpeechAnalyzer`, fusion des pistes |
| `TranscriptStore.swift` | Transcripts sur disque : lecture, libellé, `meta.json`, regroupement par jour |
| `TranscriptsView.swift` | Fenêtre des transcripts : liste et vue détail |
| `FloatingStopController.swift` / `FloatingStopView.swift` | Panneau flottant Liquid Glass |
| `Log.swift` | Loggers `os.Logger` (sous-système `com.cletetour.sillage`) |

## Limites connues

- Sur **haut-parleurs**, le micro capte le son système (écho) → le même passage
  peut apparaître dans les deux pistes. **Utilise un casque** pour l'éviter.
  (Une annulation d'écho logicielle est envisagée.)
- La **langue est fixée à `fr-FR`** dans le code : Sillage transcrit en français
  quelle que soit la langue du système.
- Le tap système ne livre de l'audio **que quand du son sort effectivement**. Si
  la permission « enregistrement des sons du système » n'est pas accordée, la
  piste système reste vide et seul le micro est transcrit — sans erreur, mais
  sans lignes « Interlocuteur » dans le transcript.
- Nécessite macOS 26 (API `SpeechAnalyzer` et *Liquid Glass*).

## Licence

[MIT](LICENSE) © 2026 Clément Letetour
