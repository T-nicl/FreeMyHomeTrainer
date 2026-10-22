# FreeMyHomeTrainer

Application macOS pour faire des séances structurées sur home trainer, sans abonnement et sans
monde virtuel : tu crées tes séances (« 3x10' à 200 W »), l'app pilote le trainer en mode ERG,
affiche la puissance, la cadence et la fréquence cardiaque, puis envoie la sortie sur Strava
et Garmin Connect.

## Fonctionnalités

- **Éditeur visuel de séances** : blocs constants, rampes et répétitions, à glisser-déposer ;
  cibles en watts ou en % de FTP ; note d'intensité de 1 à 5.
- **Pilotage du home trainer** en Bluetooth (protocole standard FTMS, mode ERG), prévu pour
  le Wahoo KICKR Core et compatible avec la plupart des trainers récents.
- **Ceinture cardio** Bluetooth.
- **Pendant la séance** : grands chiffres, profil avec la puissance réelle, bips aux changements
  d'intervalle, pause automatique, intensité ±5 % (↑ / ↓), passer un intervalle.
- **Historique** avec courbes et intervalles, export `.fit`.
- **Envoi automatique** sur Strava (API officielle) et Garmin Connect (non officiel, voir plus bas).
- **Trainer simulé** pour essayer l'app sans vélo.

## Installation (depuis le code)

Prérequis : un Mac sous macOS 15 ou plus récent, et [Xcode](https://apps.apple.com/app/xcode/id497799835) 16 ou plus.

1. Récupère le code : `git clone https://github.com/<compte>/FreeMyHomeTrainer.git`
2. Ouvre `FreeMyHomeTrainer.xcodeproj` dans Xcode.
3. Choisis le schéma **FreeMyHomeTrainer** et lance avec **⌘R**.

Par défaut, l'app est signée localement (« Sign to Run Locally ») : aucun compte Apple Developer
n'est nécessaire. Au premier lancement, macOS demande l'autorisation d'utiliser le Bluetooth.

### Réglages personnels (facultatif)

Copie `Config/Local.xcconfig.example` en `Config/Local.xcconfig` (ce fichier n'est jamais envoyé
sur GitHub) pour :

- signer avec ton compte Apple (`CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`) ;
- intégrer les clés de ton application Strava (voir ci-dessous).

## Strava

L'app utilise l'API officielle de Strava, qui demande une « application » Strava :

1. Va sur <https://www.strava.com/settings/api> et crée une application (gratuit).
2. Mets `localhost` comme **Authorization Callback Domain**.
3. Copie le **Client ID** et le **Client Secret** dans `Config/Local.xcconfig`
   (`STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`), puis recompile.
4. Dans l'app : **Réglages › Comptes › Connecter Strava**.

⚠️ Une nouvelle application Strava n'accepte qu'**un seul athlète** (son créateur). Pour que des
amis puissent se connecter avec une app compilée avec tes clés, demande une augmentation de
capacité à Strava depuis la page de ton application. Sinon, chacun peut créer sa propre
application Strava et saisir ses clés dans les Réglages.

## Garmin Connect (expérimental)

Garmin ne propose pas d'API publique aux particuliers. L'app ouvre la page de connexion
officielle de Garmin, récupère un jeton (le mot de passe n'est jamais vu par l'app) et envoie
le `.fit` comme le fait l'app mobile Garmin Connect — même méthode que la librairie open source
[garth](https://github.com/matin/garth). Cela peut cesser de fonctionner si Garmin change sa
connexion ; l'export `.fit` depuis l'historique reste possible pour un import manuel sur
connect.garmin.com.

Les jetons Strava et Garmin sont stockés dans le Trousseau macOS.

## Développement

- SwiftUI + Swift 6, SwiftData, Swift Charts, CoreBluetooth. Aucune dépendance externe.
- Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) à partir de
  `project.yml` : après une modification de `project.yml`, lance `xcodegen generate`.
- Tests : `xcodebuild -scheme FreeMyHomeTrainer test` (ou ⌘U dans Xcode).

| Dossier | Contenu |
| --- | --- |
| `Model/` | Séances (format JSON), timeline, note d'intensité, persistance |
| `Bluetooth/` | FTMS (trainer), cardio, trainer simulé |
| `Engine/` | Déroulé de la séance, enregistrement, statistiques |
| `Export/` | Encodeur `.fit`, Strava, Garmin |
| `Views/` | Interface SwiftUI |

Le format JSON des séances est volontairement simple pour qu'un LLM (Ollama, Mistral…) puisse
plus tard générer une séance à partir d'une phrase comme « séance tempo 3x10' » :

```json
{"name": "Tempo 3x10'", "blocks": [
  {"type": "ramp", "duration": 600, "from": {"ftp": 50}, "to": {"ftp": 70}},
  {"type": "repeat", "count": 3, "blocks": [
    {"type": "steady", "duration": 600, "target": {"ftp": 85}},
    {"type": "steady", "duration": 300, "target": {"watts": 120}}]}]}
```

## Licence

[MIT](LICENSE)
