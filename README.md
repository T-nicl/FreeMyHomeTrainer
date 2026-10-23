# FreeMyHomeTrainer

Application macOS pour faire des séances structurées sur home trainer, sans abonnement et sans
monde virtuel : tu crées tes séances (« 3x10' à 200 W »), l'app pilote le trainer en mode ERG,
affiche la puissance, la cadence et la fréquence cardiaque, puis envoie la sortie sur
Garmin Connect.

## Fonctionnalités

- **Éditeur visuel de séances** : blocs constants, rampes et répétitions (imbricables), à
  glisser-déposer ; cibles en watts ; note d'intensité de 1 à 5 ; alerte si une séance paraît
  irréaliste pour ta FTP.
- **Pilotage du home trainer** en Bluetooth (protocole standard FTMS, mode ERG), prévu pour
  le Wahoo KICKR Core et compatible avec la plupart des trainers récents.
- **Ceinture cardio** Bluetooth.
- **Pendant la séance**, à la manière de Zwift : watts en très grand (verts dans la cible, orange
  avec « Accélère » / « Ralentis » sinon), cardio et cadence ; bloc en cours avec temps restant et
  barre de progression ; profil avec ta puissance réelle ; bips aux changements d'intervalle ;
  pause automatique ; intensité ±5 % (↑ / ↓) ; passer un intervalle.
- **Mini-fenêtre** au-dessus de tout, même d'une vidéo en plein écran.
- **Sortie libre avec vitesses virtuelles** : 24 vitesses (− / + ou ↓ / ↑), le trainer simule un
  vélo sur le plat.
- **Historique** avec courbes et intervalles, export `.fit`.
- **Envoi sur Garmin Connect**, manuel ou automatique après la séance.
- **Trainer simulé** pour essayer l'app sans vélo.
- 🚧 **Créer une séance avec l'IA** : en chantier, voir plus bas.

## Installer l'app

Pas besoin de Xcode. Télécharge la dernière version sur la page
[Releases](https://github.com/T-nicl/FreeMyHomeTrainer/releases/latest) (fichier
`FreeMyHomeTrainer-X.Y.Z.zip`), puis :

1. Double-clique sur le `.zip` et glisse **FreeMyHomeTrainer** dans **Applications**.
2. Ouvre l'app : macOS refuse, car elle n'est pas validée par Apple. Clique sur **OK**.
3. Ouvre **Réglages Système › Confidentialité et sécurité**, descends tout en bas et clique sur
   **Ouvrir quand même**, puis confirme avec le mot de passe du Mac. C'est à faire une seule fois.
4. Autorise le Bluetooth quand l'app le demande.

Pour mettre à jour, remplace l'app dans Applications par la nouvelle version : les séances,
l'historique et la connexion Garmin sont conservés. Nécessite macOS 15 ou plus récent
(Apple Silicon ou Intel).

> Pourquoi cet avertissement ? Faire valider (« notariser ») une app par Apple demande le
> programme Apple Developer payant. L'app est signée avec un certificat gratuit : elle
> fonctionne normalement, mais macOS demande une confirmation au premier lancement. Ce
> certificat est renouvelé chaque année : après une version signée avec un nouveau certificat,
> il faudra peut-être reconnecter ton compte Garmin (tes séances et ton historique restent).

## Premiers pas

1. **Réglages** : indique ta **FTP** et ton **poids** (ils servent aux cibles, à la note
   d'intensité et à la vitesse virtuelle).
2. **Rouler** : dans le panneau **Capteurs**, connecte ton home trainer et ta ceinture cardio
   (ils sont retrouvés automatiquement aux lancements suivants).
3. Choisis une séance (ou **Sortie libre**) et clique sur **Démarrer**. Espace = pause,
   **Terminer** enregistre la sortie.
4. Crée ou modifie tes séances dans l'onglet **Séances**.

## Garmin Connect

Dans l'app : **Réglages › Comptes › Connecter Garmin**. L'app te demande ton e-mail et ton mot de
passe Garmin (puis le code reçu si la validation en deux étapes est active) et les transmet
directement à Garmin. Le mot de passe sert uniquement à cette connexion et n'est jamais
enregistré : l'app ne garde que les jetons de connexion, dans le Trousseau macOS.

Chaque sortie peut alors être envoyée sur Garmin Connect depuis l'historique (« Envoyer sur
Garmin »), ou automatiquement après la séance si tu actives l'option dans les Réglages
(désactivée par défaut).

> ⚠️ **Connexion non officielle.** Garmin ne propose pas d'API publique aux particuliers : l'app
> se connecte comme l'app mobile Garmin Connect (même méthode que la librairie open source
> [garth](https://github.com/matin/garth)). Ça fonctionne bien aujourd'hui, mais ça peut cesser
> de fonctionner du jour au lendemain si Garmin change sa connexion. Dans ce cas, le fichier
> `.fit` reste exportable depuis l'historique pour un import manuel sur connect.garmin.com.

## 🚧 Créer des séances avec l'IA (en chantier)

**Cette partie ne marche pas encore bien dans cette version** : les séances simples (« tempo
3x10' », « VO2 max 5x3' ») sortent correctement, mais les demandes plus subtiles (pyramides,
durée totale imposée, over-under) donnent souvent des séances fausses. Relis toujours la séance
avant de l'ajouter ; elle reste modifiable dans l'éditeur.

Le bouton ✨ de la liste des séances utilise [Ollama](https://ollama.com), qui fait tourner un
modèle de langage sur ton Mac (gratuit, hors ligne, rien n'est envoyé en ligne). Pour essayer,
dans le Terminal :

```sh
brew install ollama
brew services start ollama      # lance Ollama, et à chaque démarrage du Mac
ollama pull qwen2.5:7b          # le modèle par défaut, ≈ 4,7 Go
```

(Sans Homebrew : installe l'app depuis ollama.com, puis `ollama pull qwen2.5:7b`.) Un Mac Apple
Silicon avec 16 Go de mémoire est confortable. Dans **Réglages › Assistant IA**, tu peux choisir
un autre modèle installé et vérifier la connexion.

## Pour les développeurs

### Compiler depuis le code

Prérequis : macOS 15 ou plus récent et [Xcode](https://apps.apple.com/app/xcode/id497799835) 16
ou plus.

1. `git clone https://github.com/T-nicl/FreeMyHomeTrainer.git`
2. Ouvre `FreeMyHomeTrainer.xcodeproj`, choisis le schéma **FreeMyHomeTrainer** et lance avec **⌘R**.

Par défaut, l'app est signée localement (« Sign to Run Locally ») : aucun compte Apple Developer
n'est nécessaire. Pour signer avec ton compte Apple, copie `Config/Local.xcconfig.example` en
`Config/Local.xcconfig` (jamais envoyé sur GitHub) et renseigne `CODE_SIGN_IDENTITY` et
`DEVELOPMENT_TEAM`.

### Organisation

- Spécification fonctionnelle (écrans, règles de calcul, format des séances) : [SPEC.md](SPEC.md).
- SwiftUI + Swift 6, SwiftData, Swift Charts, CoreBluetooth. Aucune dépendance externe.
- Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) à partir de
  `project.yml` : après une modification de `project.yml`, lance `xcodegen generate`.
- Tests : `xcodebuild -scheme FreeMyHomeTrainer test` (ou ⌘U dans Xcode). Évaluation du
  générateur de séances avec le vrai modèle (lente) : `TEST_RUNNER_OLLAMA_EVAL=1 xcodebuild …
  test -only-testing:FreeMyHomeTrainerTests/OllamaEvaluation` (`TEST_RUNNER_OLLAMA_MODEL` pour
  un autre modèle).
- Publier une version : `scripts/release.sh X.Y.Z` (build universel signé, `.zip`, release
  GitHub). `scripts/release.sh --build-only` fabrique seulement le `.zip`.

| Dossier | Contenu |
| --- | --- |
| `Model/` | Séances (format JSON), timeline, note d'intensité, générateur de séances, persistance |
| `Bluetooth/` | FTMS (trainer), cardio, trainer simulé |
| `Engine/` | Déroulé de la séance, vitesses virtuelles, enregistrement, statistiques |
| `Export/` | Encodeur `.fit`, envoi Garmin, client Ollama |
| `Views/` | Interface SwiftUI |

Format JSON des séances (import / export) :

```json
{"name": "Tempo 3x10'", "blocks": [
  {"type": "ramp", "duration": 600, "from": {"watts": 110}, "to": {"watts": 170}},
  {"type": "repeat", "count": 3, "blocks": [
    {"type": "steady", "duration": 600, "target": {"watts": 210}},
    {"type": "steady", "duration": 300, "target": {"watts": 120}}]}]}
```

## Licence

[MIT](LICENSE)
