# FreeMyHomeTrainer — Spécification fonctionnelle

Ce document décrit **ce que fait l'app et selon quelles règles**. Il fait foi pour les évolutions :
toute nouvelle fonctionnalité ou tout changement de règle doit y être reporté. Le « comment »
(architecture, pièges techniques) est dans `CLAUDE.md` ; l'installation est dans `README.md`.

## 1. Vision

Remplacer Zwift pour un usage **d'entraînement structuré uniquement** : pas de monde virtuel,
pas de partie en ligne, pas d'abonnement. L'utilisateur crée ses séances, l'app pilote le home
trainer en mode ERG, affiche l'essentiel pendant l'effort, enregistre la sortie et l'envoie à
Garmin Connect (qui la transmet à Strava).

- **Utilisateurs** : l'auteur et quelques proches, sur Mac (macOS 15 ou plus, Apple Silicon ou Intel).
- **Langue** : interface entièrement en français.
- **Matériel de référence** : Wahoo KICKR Core (Zwift Cog) en Bluetooth FTMS, ceinture cardio BLE.

## 2. Écrans

Barre latérale : **Rouler** (écran d'accueil), **Séances**, **Historique**, **Réglages**.
Fenêtre de 1000 × 680 points minimum ; aucun contenu ne doit être coupé à cette taille.

### 2.1 Rouler — préparation
- Panneau **Capteurs** : état du Bluetooth, home trainer et cardio (nom, état, mesures),
  recherche d'appareils, connexion, « Oublier », bascule **Trainer simulé**.
- Panneau **Comptes** (compact) : connexion Garmin.
- Choix de la séance (même ordre que la liste des séances) ou **Sortie libre** (pas de consigne
  ERG, pente nulle).
- Aperçu : profil, durée, puissance moyenne, note d'intensité, alerte « séance irréaliste »
  (§ 4.3), notes de la séance.
- **Démarrer** n'est possible que si un trainer est connecté (réel ou simulé). Si la séance
  demande l'ERG et que le trainer n'a pas accepté le contrôle, un avertissement est affiché.

### 2.2 Rouler — séance en cours
Disposition inspirée de Zwift, de haut en bas :
- **Trois grands chiffres**, de même taille : **watts** (moyenne 3 s, verts à ±5 % de la cible,
  orange en dessous, rouges au-dessus, avec la cible dessous), **cardio** (bpm, en rouge),
  **cadence** (rpm).
- **Carte du bloc en cours**, à la couleur de sa zone : libellé (durée @ puissance), répétition
  (n / total), **temps restant du bloc** en gros, **barre de progression** du bloc (vide au début,
  pleine à la fin), « Ensuite : … » ou « Dernier bloc ». Masquée en sortie libre et une fois la
  séance terminée.
- Ligne secondaire, en petit : **temps** roulé, **reste** de la séance, **vitesse** (km/h),
  **distance**.
- Profil complet avec curseur de position et puissance réelle tracée par-dessus ; séance terminée
  (roue libre), le curseur reste au bout du profil et la courbe réelle s'y arrête.
- Commandes : intensité −5 % / +5 % (flèches ↓ ↑), **Suivant** (passe l'intervalle), **Mini**,
  **Pause** (espace), **Terminer** (avec confirmation).
- Badges : « En pause », « Pause auto — pédale pour reprendre », « Séance terminée — roue libre ».
- Sons : un bip 4 s avant un changement d'intervalle, un autre au début du suivant.
- L'écran ne se met pas en veille pendant une séance.

### 2.3 Mini-fenêtre (« Mini »)
- Petit panneau en haut à droite, au-dessus de toutes les fenêtres, **y compris une vidéo en
  plein écran** ; ne prend jamais le focus (cliquer dessus ne fait pas sortir la vidéo du plein
  écran) ; déplaçable.
- Contenu : puissance / cible, temps d'intervalle (ou temps écoulé en sortie libre), barre de
  progression de l'intervalle, cardio, cadence, vitesse, boutons Pause et « Revenir à l'app ».
- La fenêtre principale se range dans le Dock et revient au premier plan avec « Revenir ».
  La mini-fenêtre se ferme à la fin de la séance.

### 2.4 Fin de séance
Résumé (statistiques, état de l'envoi Garmin), puis « Voir dans l'historique » ou « Nouvelle
sortie ». Une séance arrêtée sans aucun échantillon n'est pas enregistrée.
**Une séance n'est jamais perdue** : si l'enregistrement échoue, elle reste en mémoire et
l'alerte propose « Réessayer », « Abandonner la séance… » (avec confirmation) ou « Plus tard »
(« Terminer » relance l'enregistrement). Aucun demi-enregistrement : ni fiche, ni .fit orphelin.

### 2.5 Séances (bibliothèque et éditeur)
**Liste** (colonne de gauche) :
- En-tête « Mes séances » avec **Nouvelle séance** (⌘N) ; la nouvelle séance arrive en tête.
  Bouton **étincelles** (⇧⌘N) : « Créer avec l'IA » (§ 2.5 bis).
- Chaque ligne : nom, durée, mini-profil, note d'intensité.
- **Ordre manuel** par glisser-déposer, enregistré.
- Sous la liste : **Dupliquer** (la copie se place sous l'original) et **Supprimer**.
- **⌫** supprime la séance sélectionnée ; toute suppression demande confirmation ; la séance
  suivante est alors sélectionnée. L'historique n'est jamais touché.
- Menu contextuel : Rouler cette séance, Dupliquer, Supprimer.

**Noms uniques** : deux séances ne portent jamais le même nom (comparaison insensible à la
casse, aux accents et aux espaces autour). Création : « Nouvelle séance », « Nouvelle séance 2 »…
Copie : « X (copie) », « X (copie) 2 »… Renommage vers un nom pris : message orange pendant la
saisie, numéro ajouté à la validation. Nom vide → « Séance sans nom ». Les doublons existants
sont renumérotés à l'ouverture de la liste.

**Éditeur** (de haut en bas) :
1. Nom (titre), bouton **Rouler**, résumé (durée, puissance moyenne, intensité), notes.
2. Bandeau « séance irréaliste » le cas échéant.
3. Aperçu de la séance complète (répétitions déroulées) avec le trait de la FTP.
4. Palette **Ajouter : Bloc · Répétition** (clic = ajout après la sélection, glisser = dépôt
   à l'endroit voulu).
5. **Frise** : un bloc = une barre (largeur ∝ durée, hauteur ∝ puissance, couleur de zone,
   coins arrondis) ; une rampe = une pente ; une répétition = un cadre « × n » avec boutons
   − / + ; trait pointillé de la FTP ; libellés durée et puissance sous chaque barre.
6. **Barre d'édition** du bloc sélectionné : type (Constant / Rampe), durée (« 10 », « 10:30 »,
   « 10'30 », « 1:00:00 », ± 30 s), puissance en watts (± 5 W) avec l'équivalent « ≈ x % FTP » ;
   pour une répétition : nombre (1 à 50) et ajout d'un bloc ou d'une répétition à l'intérieur.
   Dupliquer (⌘D), Supprimer (⌫).

**Gestes dans la frise** :
- Clic : sélectionner ; clic dans le vide : désélectionner.
- Tirer le **bord droit** d'un bloc : durée, par pas de 15 s (minimum 15 s).
- Tirer le **haut** : puissance, par pas de 5 W (0 à 2000 W) ; une rampe a deux poignées
  (moitié gauche = début, moitié droite = fin). Les valeurs s'affichent en gras pendant le geste.
- **Glisser un bloc** : une étiquette suit le pointeur, le bloc d'origine est estompé, un seul
  trait gris indique l'emplacement d'arrivée :
  - moitié gauche / droite d'un bloc → avant / après lui ;
  - bord (18 pt) d'une répétition → avant / après elle ; milieu → dedans (cadre surligné) ;
  - ailleurs dans la frise → d'après la position horizontale.
  Au lâcher, le bloc est posé directement à cet emplacement. Hors de la frise, sur lui-même ou
  dans ses propres sous-blocs : annulé (étiquette semi-transparente).
- Les **répétitions peuvent s'imbriquer** à toute profondeur (ex. 2 × (8 × 1'/1') + récup).

### 2.5 bis Créer avec l'IA (LLM local)
Fenêtre ouverte depuis la liste des séances : on décrit la séance en français (« séance tempo
3x10' ») et un LLM **local** (Ollama, sur le Mac de l'utilisateur, rien n'est envoyé en ligne)
la construit.
- Champ de demande (↩ ou **Créer**) et exemples cliquables (tempo, sweet spot, VO2 max, 30/30,
  endurance, pyramide).
- Pendant la génération (quelques secondes à une minute) : indicateur et **Interrompre**.
- **Aperçu** : nom, notes, résumé (durée, puissance moyenne, intensité), profil avec la FTP,
  bandeau « séance irréaliste » le cas échéant.
- **Ajuster…** (« un peu plus dur », « échauffement plus long ») : le modèle reçoit la séance
  affichée et renvoie la séance complète modifiée. Un échec garde la séance précédente.
- **Ajouter à mes séances** : en tête de liste, nom rendu unique, ouverte dans l'éditeur.
  **Annuler** : rien n'est créé.
- Erreurs en français : Ollama ne répond pas (le lancer), modèle absent (`ollama pull …`),
  délai dépassé, réponse inattendue, séance invalide après réparation.

Règles :
- Requête `POST /api/chat` d'Ollama, sans streaming, réponse plafonnée (2 000 jetons, 1 Mo).
- Le modèle ne compose pas les blocs : il remplit un **plan** dont chaque champ est obligatoire
  (schéma JSON passé en `format`) : nom, notes, minutes d'échauffement, **séries** (nombre,
  efforts en minutes et watts, récupération en minutes et watts), minutes de retour au calme.
  L'app en fait la séance : échauffement en rampe 45 → 70 % FTP, chaque série répétée (répétition
  si nombre > 1, récupération omise si 0 minute), retour au calme en rampe 60 → 40 % FTP, watts
  arrondis à 5 W. (Avec l'arbre de blocs complet, Qwen 2.5 7B oubliait récupérations et
  échauffement et confondait minutes et secondes.)
- Consignes au modèle : FTP et zones de Coggan **en watts**, vocabulaire (tempo ≈ 85 %, sweet spot
  ≈ 90 %, seuil ≈ 100 %, VO2 ≈ 115 %), récupérations par défaut, cinq plans d'exemple calculés
  pour la FTP de l'utilisateur.
- La séance obtenue passe par les limites du § 3. Refusée (ou plan illisible) → **un seul**
  nouvel essai, en renvoyant le message d'erreur au modèle ; sinon, erreur affichée.
- Adresse d'Ollama : HTTP en clair seulement vers le Mac ou le réseau local, HTTPS ailleurs ;
  redirections non suivies.
- Conversation envoyée : consignes, demande d'origine et derniers échanges (10 messages au plus).

### 2.6 Historique
- Liste des sorties : nom, date, temps, puissance moyenne, note d'intensité.
- Détail : durée, distance, vitesse moyenne, puissance moyenne et max, intensité, FC moyenne /
  max, cadence moyenne, travail (kJ) ; courbes puissance (avec la cible), FC, cadence ;
  tableau des intervalles (durée, cible, puissance moyenne et max, FC, cadence).
- Envoi Garmin : « Envoyer sur Garmin », état (en cours, ✓, échec + « Renvoyer »), message
  d'erreur. **Exporter le .FIT…** à tout moment. Suppression avec confirmation (la sortie reste
  sur Garmin / Strava si elle y a été envoyée).

### 2.7 Réglages
- Profil : **FTP** (50 à 600 W, défaut 200), **poids** (défaut 70 kg), rapport W/kg.
- Comptes : **Connecter Garmin** (e-mail, mot de passe, puis code de vérification si la double
  authentification est active), Déconnecter, option **envoi automatique** (désactivée par
  défaut), aide pour activer la synchronisation Garmin → Strava.
- Assistant IA : **adresse d'Ollama** (défaut `http://localhost:11434`, http/https, hôte et port
  seulement), **modèle** (modèles installés ; défaut `qwen2.5:7b`), état de la connexion testé à
  l'ouverture et via **Tester** (modèle non installé signalé), aide à l'installation.
- Numéro de version de l'app.

## 3. Séances : modèle et format

Une séance = nom, notes facultatives, liste de blocs :
- **steady** : durée + cible ;
- **ramp** : durée + cible de début + cible de fin (variation linéaire) ;
- **repeat** : nombre + liste de blocs (imbrication libre).

Cible = **watts** (par défaut, et pour tout bloc créé ou modifié) ou **% de FTP** (séances
d'exemple ; suit la FTP si elle change). Le format JSON est volontairement simple pour qu'un
LLM puisse le produire :

```json
{"name": "Tempo 3x10'", "notes": "facultatif", "blocks": [
  {"type": "ramp", "duration": 600, "from": {"ftp": 50}, "to": {"ftp": 70}},
  {"type": "repeat", "count": 3, "blocks": [
    {"type": "steady", "duration": 600, "target": {"watts": 200}},
    {"type": "steady", "duration": 300, "target": {"watts": 120}}]}]}
```

Séances d'exemple créées au premier lancement : Sweet Spot 3x10', Tempo 2x20', VO2 max 5x3',
Endurance 1h.

**Limites** (aucune séance ne doit pouvoir figer ou planter l'app) : répétitions 1 à 50,
imbrication sur 4 niveaux, 5 000 segments une fois déroulée, 2 000 blocs, bloc de 1 s à 24 h,
séance de 24 h au plus, 0 à 2 500 W ou 0 à 1 000 % FTP, pas de répétition vide, nom ≤ 100 et
notes ≤ 5 000 caractères, fichier importé ≤ 256 Ko.
- Séance **importée** (JSON, LLM, ami) hors limites → refusée avec un message en français.
- Séance **enregistrée** hors limites → ramenée dans les limites au chargement (valeurs bornées,
  blocs de durée nulle retirés, répétitions vides retirées, imbrication excessive aplatie).
- **Éditeur** : saisie bornée (2 500 W, 24 h) ; si la séance dépasse malgré tout une limite, un
  bandeau « Cette séance dépasse les limites de l'app » l'explique.

## 4. Règles de calcul

### 4.1 Zones de puissance (Coggan, % FTP)
Z1 < 56 (gris) · Z2 56–75 (bleu) · Z3 76–90 (vert) · Z4 91–105 (jaune) · Z5 106–120 (orange) ·
Z6 > 120 (rouge).

### 4.2 Note d'intensité (1 à 5, par demi-points)
Remplace TSS / IF à l'écran (ils restent dans le .FIT). Courbe sur l'IF (NP / FTP), corrigée en
continu par la durée (référence 1 h : −1,5 au plus pour une séance très courte, +0,75 au plus
au-delà de 2 h). Calibrage validé (FTP 245 W) :

| Séance | Note |
| --- | --- |
| 45' à 170 W | 1,5 |
| Endurance 1 h (≈ 66 %) | 1,5 |
| Tempo 2x20' | 2 |
| Sweet spot 3x10' | 2,5 |
| VO2 5x3', seuil 2x20' | 4 |
| 100 % FTP : 10' / 26' / 45' / 1 h | 3,5 / 4 / 4,5 / 5 |
| 45' à 250 W | 5 |

Libellés : < 1,5 très facile · < 2,5 facile · < 3,5 modérée · < 4,5 difficile · sinon très difficile.

### 4.3 Séance irréaliste (avertissement, jamais bloquant)
Modèle de puissance critique : durée tenable au-dessus de 105 % de la FTP = W' / (P − FTP), avec
W' ≈ 82 J par watt de FTP (≈ 7' à 120 %, ≈ 80 s à 200 %, ≈ 25 s à 400 %). Un bloc est signalé
s'il dépasse 1,5 fois cette durée, ou s'il dépasse 2000 W, ou plus de 75' à ≥ 95 % de la FTP, ou
plus de 3 h à ≥ 85 % ; la séance est signalée si elle dépasse 6 h. Les séances d'exemple et les
séances dures mais réalistes (5x3' à 118 %, 30/30 à 150 %, 1 h à la FTP) ne déclenchent rien.

### 4.4 Déroulé d'une séance
- Horloge à 1 Hz. **Temps roulé** (`elapsed`, pauses exclues, c'est le temps enregistré) et
  **position dans la séance** (`position`, saute en avant quand on passe un intervalle) sont
  distincts.
- Consigne ERG envoyée à chaque changement de cible arrondie, au plus une fois par seconde
  (rampes comprises), multipliée par l'intensité (50 à 150 %), bornée par la plage du trainer.
- **Pause auto** après 3 s sans pédaler (cadence et puissance nulles), reprise dès qu'on pédale.
  Pause manuelle par bouton ou espace.
- Écart d'horloge plafonné à 2 s (une mise en veille ne compte pas comme temps roulé).
- Fin du déroulé : la consigne ERG est relâchée (pente 0), l'enregistrement continue jusqu'à
  « Terminer ». « Terminer » en cours de séance relâche aussi l'ERG.
- Après une reconnexion du trainer ou une reprise de contrôle, la consigne en cours est
  renvoyée immédiatement (y compris en pause). Si le trainer signale que le contrôle a été pris
  par une autre app, ou refuse une consigne faute de contrôle, l'app le redemande, au plus une
  fois toutes les 10 s.
- Le chrono et le pilotage continuent pendant un déplacement de fenêtre ou un menu ouvert.
- Un **tour** (lap) par segment de la séance ; la roue libre après la fin forme un dernier tour.

### 4.5 Vitesse et distance virtuelles
Vélo de route sur le plat, sans vent : masse = poids + 8 kg, Crr 0,004, CdA 0,32 m², air
1,225 kg/m³, rendement 97,5 %, avec inertie (accélération progressive, roue libre). Repères pour
70 kg : 100 W ≈ 27 km/h, 200 W ≈ 35 km/h, 300 W ≈ 40 km/h. Vitesse nulle en pause. La vitesse
remontée par le trainer n'est pas utilisée.

### 4.6 Statistiques d'une sortie
Puissance moyenne et max, NP (moyenne glissante 30 s puissance 4), IF, TSS, travail (kJ), FC
moyenne et max (hors 0), cadence moyenne (hors arrêts), distance.

## 5. Matériel

- **Home trainer** : FTMS (service 0x1826) — Indoor Bike Data, Control Point (prise de contrôle,
  démarrage, puissance cible, simulation de pente), plage de puissance, état. Une seule
  commande à la fois ; une consigne en attente remplace la précédente ; délai de 2 s.
- **Cardio** : service Heart Rate (0x180D), FC sur 8 ou 16 bits ; à défaut, la FC remontée par
  le trainer.
- Mesures considérées perdues après 3 s (trainer) / 5 s (cardio) sans données.
- Appareils mémorisés et reconnectés automatiquement ; reconnexion après une coupure.
- **Trainer simulé** : suit la consigne avec inertie et bruit, cadence ≈ 88, FC liée à la puissance.

## 6. Enregistrement et envoi

- Échantillons à 1 Hz : horodatage, temps roulé, position, puissance, cadence, FC, vitesse,
  distance, cible.
- **Fichier .FIT** (vélo d'intérieur) : file_id, events (y compris pauses), records, un lap par
  tour, session (NP, TSS, IF, FTP), activity. Validé avec le SDK FIT officiel de Garmin.
- **Garmin Connect** (non officiel) : connexion par le formulaire de l'app ; le mot de passe
  n'est jamais stocké, seuls les jetons vont dans le Trousseau (si le Trousseau refuse, la
  connexion échoue clairement). Envoi manuel par défaut, automatique en option ; un doublon (409)
  compte comme un succès ; un seul envoi à la fois par sortie.
  - Jeton d'accès refusé (401) : renouvelé puis un seul nouvel essai. Jeton longue durée refusé :
    compte déconnecté, message « reconnecte ton compte ».
  - Envoi interrompu par la fermeture de l'app : marqué en échec au lancement suivant (une fois
    par lancement), avec « Renvoyer ».
  - Messages d'erreur courts : jamais la réponse brute du serveur. Aucune redirection suivie hors
    de garmin.com (HTTPS uniquement).
- **Fichier .FIT** : une pause est enregistrée quand l'heure avance alors que le temps roulé est
  arrêté (plus de 1,5 s d'écart) ; heure locale avec le décalage du fuseau, signé.
- **Strava** : via la synchronisation Garmin Connect → Strava (pas d'envoi direct : l'API
  Strava exige un abonnement payant depuis juin 2026).

## 7. Distribution

- Code public : github.com/T-nicl/FreeMyHomeTrainer (licence MIT).
- Versions installables sans Xcode : `scripts/release.sh X.Y.Z` → app universelle signée avec
  un certificat gratuit, `.zip` publié dans les Releases GitHub. Pas de notarisation : au premier
  lancement, « Ouvrir quand même » dans Réglages Système › Confidentialité et sécurité.

## 8. Hors périmètre

Monde virtuel, multijoueur, classements, connexion à un compte en ligne propre à l'app, envoi
direct vers Strava, mode pente réaliste (parcours), applications iOS / Windows.

## 9. Évolutions prévues


Aucune pour le moment.
