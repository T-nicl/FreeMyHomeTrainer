# FreeMyHomeTrainer

Application macOS pour faire des séances structurées sur home trainer, sans abonnement et sans
monde virtuel : tu crées tes séances (« 3x10' à 200 W »), l'app pilote le trainer en mode ERG,
affiche la puissance, la cadence et la fréquence cardiaque, puis envoie la sortie sur
Garmin Connect, qui la transmet à Strava.

## Fonctionnalités

- **Éditeur visuel de séances** : blocs constants, rampes et répétitions, à glisser-déposer ;
  cibles en watts ou en % de FTP ; note d'intensité de 1 à 5.
- **Pilotage du home trainer** en Bluetooth (protocole standard FTMS, mode ERG), prévu pour
  le Wahoo KICKR Core et compatible avec la plupart des trainers récents.
- **Ceinture cardio** Bluetooth.
- **Pendant la séance** : grands chiffres, profil avec la puissance réelle, bips aux changements
  d'intervalle, pause automatique, intensité ±5 % (↑ / ↓), passer un intervalle.
- **Historique** avec courbes et intervalles, export `.fit`.
- **Envoi** sur Garmin Connect (manuel, ou automatique en option), puis Strava via la
  synchronisation Garmin → Strava.
- **Trainer simulé** pour essayer l'app sans vélo.

## Installation (depuis le code)

Prérequis : un Mac sous macOS 15 ou plus récent, et [Xcode](https://apps.apple.com/app/xcode/id497799835) 16 ou plus.

1. Récupère le code : `git clone https://github.com/T-nicl/FreeMyHomeTrainer.git`
2. Ouvre `FreeMyHomeTrainer.xcodeproj` dans Xcode.
3. Choisis le schéma **FreeMyHomeTrainer** et lance avec **⌘R**.

Par défaut, l'app est signée localement (« Sign to Run Locally ») : aucun compte Apple Developer
n'est nécessaire. Au premier lancement, macOS demande l'autorisation d'utiliser le Bluetooth.

### Réglages personnels (facultatif)

Copie `Config/Local.xcconfig.example` en `Config/Local.xcconfig` (ce fichier n'est jamais envoyé
sur GitHub) pour signer avec ton compte Apple (`CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`).

## Strava et Garmin Connect

Dans l'app : **Réglages › Comptes › Connecter Garmin**. La page de connexion officielle de Garmin
s'ouvre ; l'app ne voit jamais le mot de passe et ne garde qu'un jeton, dans le Trousseau macOS.
Chaque sortie peut alors être envoyée sur Garmin Connect depuis l'historique (« Envoyer sur
Garmin »), ou automatiquement après la séance si tu actives l'option dans les Réglages.

**Pour Strava** : dans Garmin Connect, active une fois *Paramètres › Applications connectées ›
Strava*. Garmin transmet alors tes sorties à Strava automatiquement.

> Pourquoi pas d'envoi direct vers Strava ? Depuis juin 2026, créer une application sur l'API
> Strava demande un abonnement Strava payant au développeur, avec un nombre d'athlètes limité.
> Passer par Garmin Connect évite ces contraintes.

### Limite : envoi Garmin non officiel

Garmin ne propose pas d'API publique aux particuliers. L'app envoie le `.fit` comme le fait
l'app mobile Garmin Connect — même méthode que la librairie open source
[garth](https://github.com/matin/garth). Cela peut cesser de fonctionner si Garmin change sa
connexion ; l'export `.fit` depuis l'historique reste possible pour un import manuel sur
connect.garmin.com ou strava.com.

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
| `Export/` | Encodeur `.fit`, envoi Garmin |
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
