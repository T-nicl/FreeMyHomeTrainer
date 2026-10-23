# FreeMyHomeTrainer

App macOS (SwiftUI, Swift 6 strict) de séances structurées sur home trainer, pour remplacer Zwift
sans monde virtuel ni partie en ligne. Matériel de référence : Wahoo KICKR Core (Zwift Cog) en
FTMS / mode ERG + ceinture cardio BLE. L'utilisateur est francophone : **interface, commentaires
et messages de commit en français**.

## Commandes

```sh
xcodegen generate        # après tout ajout/suppression de fichier ou modif de project.yml
xcodebuild -project FreeMyHomeTrainer.xcodeproj -scheme FreeMyHomeTrainer -derivedDataPath build test
xcodebuild -project FreeMyHomeTrainer.xcodeproj -scheme FreeMyHomeTrainer -derivedDataPath build build
# Relancer l'app après un build :
osascript -e 'tell application id "fr.timothenicole.FreeMyHomeTrainer" to quit'; sleep 2
open build/Build/Products/Debug/FreeMyHomeTrainer.app
```

- Le `.xcodeproj` est généré mais **commité** (les amis l'ouvrent sans XcodeGen) : le régénérer
  et le commiter avec les changements.
- Tests : Swift Testing (`import Testing`, `#expect`). Un appel `mutating` ne peut pas être dans
  `#expect(...)` : passer par une variable locale.
- Validation FIT externe possible avec `TEST_RUNNER_FIT_DUMP=1` (écrit un `.fit` d'exemple dans le
  conteneur de l'app) puis le SDK FIT Garmin Python (`garmin-fit-sdk`).

## Architecture (`FreeMyHomeTrainer/`)

| Dossier | Rôle |
| --- | --- |
| `Model/` | `Workout` / `WorkoutBlock` (JSON simple, prévu pour être généré par un LLM), `WorkoutTimeline` (aplatissement), `IntensityRating` (note 1–5), opérations d'arbre de blocs, SwiftData (`SavedWorkout`, `ActivityRecord`) |
| `Bluetooth/` | `DeviceManager` (CoreBluetooth, FTMS + cardio, reconnexion), `FTMSParser`, `SimulatedTrainer` |
| `Engine/` | `WorkoutEngine` (déroulé, consignes ERG, pauses), `VirtualBike` (vitesse/distance fictives), `ActivityMetrics` |
| `Export/` | `FITEncoder` (maison), `GarminClient` (non officiel), `UploadCenter`, Trousseau |
| `Views/` | Rouler (écran d'accueil, mini-fenêtre flottante), Séances (éditeur), Historique, Réglages |

## Choix à respecter

- **Watts partout par défaut.** Les nouveaux blocs et toute modification enregistrent des
  `.watts` ; `.ftpPercent` n'existe plus que pour les séances d'exemple.
- **Pas de TSS / IF affichés** : remplacés par `IntensityRating` (étoiles, demi-points). Ils
  restent calculés pour le fichier FIT. Calibrage validé avec l'utilisateur (FTP 245 W) :
  45' à 170 W → 1,5 ; 45' à 250 W → 5 ; à 100 % FTP 26' → 4, 45' → 4,5, 1 h → 5. La durée
  compte en continu ; garder ces cas dans les tests si la courbe change.
- **Séances irréalistes** : `WorkoutSanity` (modèle de puissance critique, W' ≈ 82 J par W de
  FTP) affiche un bandeau orange dans l'éditeur et avant de rouler. Simple avertissement, jamais
  bloquant.
- **Temps de séance = temps réellement roulé** (`elapsed`) ; la position dans le déroulé
  (`position`) est distincte : sauter un intervalle n'ajoute pas de temps.
- **Vitesse / distance virtuelles** (`VirtualBike`) : vélo de route sur le plat, ≈ 35 km/h à
  200 W pour 70 kg. La vitesse remontée par le trainer n'est pas utilisée.
- **Strava : pas d'API directe.** Depuis juin 2026, l'API Strava exige un abonnement payant ; les
  sorties passent par Garmin Connect, qui synchronise vers Strava.
- **Garmin : connexion non officielle** (méthode « garth » : SSO → OAuth1 → OAuth2). Formulaire
  natif e-mail / mot de passe (+ code MFA) ; le mot de passe n'est jamais stocké, seuls les
  jetons vont dans le Trousseau. **Envoi automatique désactivé par défaut** (phase de test).
- **Secrets hors du dépôt** : `Config/Local.xcconfig` (signature Apple) est ignoré par git ; un
  ami compile avec la signature locale par défaut. Dépôt public : github.com/T-nicl/FreeMyHomeTrainer.

## Pièges connus (déjà rencontrés)

- **Éditeur — glisser-déposer : ne pas revenir au glisser système** (`onDrag` / `onDrop`,
  `NSItemProvider`). Asynchrone, image flottante animée par macOS, fin de glisser mal signalée,
  zones superposées dans les répétitions → repères fantômes, doubles dépôts, blocs « en survol ».
  Le glisser est interne : `DragGesture` dans le repère `EditorSpace`, positions mesurées dans
  `BlockFrames`, emplacement calculé par `BlockDropResolver` (testé), dépôt appliqué sans
  animation de trajet.
- **Fluidité du glisser** : `BlockDragState` est observé propriété par propriété. Seule
  `BlockDragOverlay` lit la position du pointeur ; le corps de l'éditeur ne doit jamais lire
  l'état du glisser (sinon tout se redessine à chaque mouvement). Ne réaffecter une propriété
  observée que si sa valeur change.
- **Redimensionnement des blocs** : gestes mesurés en repère `.global`, sinon la poignée qui se
  déplace avec le bloc fait trembler la mesure.
- **Mise en page** : la fenêtre minimale fait 1000 pt. Éviter les `fixedSize()` sur des lignes
  longues (elles débordent et coupent la fenêtre) : préférer `ViewThatFits` / lignes adaptatives.
  Dans un `Form`, un `TextField("Titre", …)` affiche son titre en double → `TextField("", …)` +
  `.labelsHidden()`.
- **Mini-fenêtre** : `NSPanel` non activant, `.canJoinAllSpaces` + `.fullScreenAuxiliary`. Pour
  revenir à l'app depuis l'arrière-plan, `NSApp.activate()` ne suffit pas (macOS 14) : passer
  aussi par `NSWorkspace.openApplication`.
- **Swift 6** : classes UI / Bluetooth en `@MainActor` ; délégués CoreBluetooth en conformance
  `@preconcurrency` ; fonctions pures appelées depuis les tests en `nonisolated`.

## Publier une version

`scripts/release.sh X.Y.Z` : met à jour la version dans `project.yml` (+ build), commite, compile
en Release universel (arm64 + x86_64), vérifie la signature, crée `dist/FreeMyHomeTrainer-X.Y.Z.zip`
(`ditto`), tague `vX.Y.Z`, pousse et crée la release GitHub avec les instructions d'installation.
`--build-only` : seulement le `.zip`, sans commit ni publication. **Toujours demander confirmation
avant de publier** (release publique).

- Pas de compte Apple Developer payant : signature avec le certificat gratuit « Apple
  Development » de `Config/Local.xcconfig` (expire en juin 2027 ; renouveler via Xcode ›
  Réglages › Comptes). Sans ce fichier, la signature serait ad hoc et changerait à chaque
  version (jetons Garmin du Trousseau perdus) : le script refuse de continuer.
- Pas de notarisation : au premier lancement, l'utilisateur clique « Ouvrir quand même » dans
  Réglages Système › Confidentialité et sécurité (README, section « Installer l'app »).

## Commits

Messages en français, première ligne courte, détail si utile, terminés par :
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. L'e-mail git du dépôt est l'adresse
masquée GitHub de l'utilisateur. Pousser sur `main` après chaque lot validé.

## Plus tard

Génération de séances par LLM local (Ollama / Mistral, « séance tempo 3x10' ») produisant le JSON
de `Workout` (voir le README), puis affichage dans l'éditeur pour validation.
