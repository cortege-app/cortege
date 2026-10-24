# Cortège

Appli de sécurité pour les manifestations, pour Android. Elle doit servir quand le réseau mobile est saturé et ne laisser aucune trace exploitable.

> **Version d'essai. Ne t'y fie pas encore si tu risques gros.**
>
> - Aucune personne extérieure n'a relu ce code. Le contrôle fait jusqu'ici est celui de l'équipe (section 20 de [ARCHITECTURE.md](ARCHITECTURE.md)).
> - Les fiches Droits et Secours sont des brouillons écrits par un assistant d'après des sources officielles. Aucun juriste ni secouriste ne les a relus ([RELECTURE-DES-FICHES.md](RELECTURE-DES-FICHES.md)). L'appli le dit sur chaque fiche.
> - La version publiée est signée avec la clé du projet. Un APK que tu construis toi-même est signé avec la clé de test d'Android.
> - Essayée sur deux téléphones Android seulement. iOS n'existe pas.

**Télécharger :** [Cortege-0.1.0-essai.apk](https://github.com/cortege-app/cortege/releases/download/v0.1.0-essai/Cortege-0.1.0-essai.apk) (53 Mo). La [page de cette version](https://github.com/cortege-app/cortege/releases/tag/v0.1.0-essai) donne l'empreinte pour vérifier le fichier. Lis d'abord le bandeau ci-dessus.

Pour utiliser l'appli pas à pas : [MODE-D-EMPLOI.md](MODE-D-EMPLOI.md).

État : étapes a à e faites et essayées sur un HONOR et un OnePlus, voir [ARCHITECTURE.md](ARCHITECTURE.md). La f (iOS) est reportée : elle demande un Mac et un iPhone. Ce qui existe aujourd'hui : verrouillage par code avec attente croissante après cinq essais ratés, code de contrainte, effacement automatique avec renouvellement du secret, coffre chiffré, fiches droits et secours (brouillons sourcés, non relus), messagerie chiffrée entre téléphones Android sans réseau (groupes par QR, relais de téléphone en téléphone par Bluetooth), mode binôme (signe de vie régulier, alerte si un proche se tait), signalement de blessé aux medics, carte hors ligne et infos signées des organisateurs (parcours, points d'eau, rendez-vous, contacts) dans un seul fichier, et partage de l'appli de téléphone à téléphone.

## Ce que l'appli garantit, et ce qu'elle ne garantit pas

Garanti par le code et vérifié par les tests :

- Aucune permission réseau dans le manifeste Android. Aucune bibliothèque de télémétrie ou de requêtes HTTP. Le test `test/no_network_test.dart` casse si l'une des deux apparaît.
- Aucun compte, aucun serveur.
- Le coffre est chiffré avec libsodium (Argon2id, XChaCha20-Poly1305). La clé vient du code et d'un secret gardé dans le Keystore Android : copier les fichiers ailleurs ne permet pas de deviner le code.
- Deux fichiers de même taille, dont un seul est le vrai coffre. Le code de contrainte ouvre l'autre, vide.
- Tout effacer détruit d'abord les secrets du Keystore : le coffre devient illisible tout de suite, même avec le bon code.

Limites à connaître :

- Le code de contrainte te sort d'un contrôle rapide. Il ne résiste pas à une analyse poussée du téléphone.
- Un code de 6 chiffres reste faible. Il est protégé par Argon2id et par le Keystore. Après cinq essais ratés, l'écran de code impose une attente qui grandit (30 secondes, puis jusqu'à 1 heure) : elle freine celui qui tape sur l'écran, pas quelqu'un qui lit les fichiers de l'appli avec un accès au système, que seuls Argon2id et le Keystore arrêtent. Pendant que le coffre est ouvert, le code reste en mémoire sous forme de texte jusqu'au passage du ramasse-miettes.
- L'effacement automatique retire les données du coffre, puis l'appli remplace le secret gardé dans le Keystore par un nouveau et détruit l'ancien : une vieille copie du fichier restée dans la mémoire flash ne se déchiffre plus. Cela ne dit rien des autres traces possibles : journal du système, mémoire vive d'un téléphone allumé.
- Si l'appli reste fermée plus longtemps que la durée d'effacement, rien n'est effacé avant la prochaine ouverture.
- Les captures d'écran sont bloquées dans l'appli.
- Deux niveaux de verrouillage. L'écran de code apparaît après 30 secondes hors de l'appli (réglable), mais la clé du coffre et le maillage restent en mémoire pour continuer à recevoir et à relayer dans ta poche. Après une durée réglable (1 heure par défaut), tout se verrouille pour de bon et le maillage s'arrête. Pendant que les clés sont en mémoire, quelqu'un qui saisit le téléphone allumé et sait lire sa mémoire pourrait les récupérer ; le réglage « Aucun » ferme tout avec l'écran de code.
- Le QR d'un groupe contient la clé du groupe : quiconque le photographie ou le scanne peut lire et écrire. Ne le publie pas.
- Les messages ne sont ni stockés ni confirmés : un message envoyé quand personne n'est à portée est perdu.
- Binôme : « un proche se tait » veut dire qu'on n'entend plus rien de lui dans le maillage (téléphone éteint, Bluetooth coupé, trop loin). L'appli ne sait pas où il est.
- Signaler un blessé : l'alerte part vers les medics avec une position arrondie à environ 200 m, sans ton nom. Tu envoies ta position précise toi-même, à un medic qui a répondu. L'appli ne demande l'accès à la position qu'à ce moment-là. Rien n'est gardé : ni position, ni historique, et les alertes disparaissent au plus tard après 2 heures.
- Le QR des medics lit toutes les alertes de l'événement. Ne le remets qu'à des medics que tu connais, en face à face. Il n'y a pas de rotation de cette clé : si un QR fuite, il faut recréer le canal.
- La boussole d'un medic vient du capteur d'orientation du téléphone. Elle est faussée près du métal, d'un haut-parleur ou d'une voiture ; tant que la position de l'alerte est approximative, elle mène à la zone, pas à la personne.
- « Aider à me trouver » : une fois qu'un medic a répondu, ton téléphone peut annoncer un signal Bluetooth que seul ce medic sait reconnaître, et faire clignoter l'écran et la lampe. Le signal s'arrête quand tu quittes l'écran. Le clignotement se voit de loin, par tout le monde. Le « chaud / froid » du medic donne une tendance sur quelques secondes, pas une direction ni une distance exacte.
- Si tu coupes le Bluetooth en cours de route, le maillage repart tout seul quand tu le rallumes (compte jusqu'à 10 secondes).
- Une alerte n'est pas confirmée tant qu'aucun medic n'a répondu. Si aucun medic n'est à portée du maillage, elle n'arrive pas. En cas de doute, appelle le 15 ou le 112.
- Le clavier du téléphone est utilisé pour écrire un message, avec l'apprentissage personnalisé désactivé. Le clavier reste celui d'Android : choisis-en un qui n'envoie rien en ligne.
- Un APK construit sans le fichier `android/key.properties` est signé avec la clé de test d'Android : il sert aux essais, pas à une diffusion. La clé du projet reste hors du dépôt. Si elle était perdue, plus aucune mise à jour ne serait possible : chaque personne devrait désinstaller l'appli et perdrait son coffre.
- Deux organisateurs dont les noms s'écrivent avec des lettres qui se ressemblent (latin et cyrillique, par exemple) ne se distinguent pas par le nom : seule l'empreinte de leur clé compte, c'est pourquoi l'appli l'affiche en grand à la première confiance.
- Argon2id met environ 160 ms à ouvrir le coffre sur les deux téléphones d'essai. Il n'a pas été réglé pour un téléphone d'entrée de gamme.
- iOS : pas encore pris en charge. L'appli refuse de créer un coffre sans protection matérielle.

## Fiches droits et secours

Les fiches sont des fichiers texte dans `app/assets/content/droits/` et `app/assets/content/secours/`. Elles sont embarquées dans l'appli, rien n'est téléchargé. Le format est décrit en tête de [fiche.dart](app/lib/content/fiche.dart).

Les neuf fiches ont été rédigées par un assistant d'intelligence artificielle, d'après des sources officielles qu'elles citent en bas de page. **Personne ne les a relues.** Chaque écran porte le bandeau jaune « À FAIRE VALIDER PAR UN JURISTE » ou « À FAIRE VALIDER PAR DES SECOURISTES », puis la phrase « Brouillon écrit par un assistant d'après des sources officielles. Personne ne l'a relu. ». Huit questions sur les soixante et une d'origine sont restées sans réponse faute de source (lignes qui commencent par `? `) : elles s'affichent sous l'étiquette « À RÉDIGER ». Ce qui reste douteux est listé dans [RELECTURE-DES-FICHES.md](RELECTURE-DES-FICHES.md). Face à un doute sur un geste de secours, appelle le 15 ou le 112.

Pour rédiger une fiche :

1. Une personne qualifiée (juriste pour les droits, secouriste pour les secours) relit le brouillon, le corrige et répond aux lignes `? `.
2. Elle ou un relecteur passe l'en-tête à `statut: valide`, ajoute `relu_par: nom, date` et retire `redaction: brouillon_source`. Le bandeau devient « Relu par ... ».
3. Tant que le statut est `a_valider`, un test n'accepte du texte que dans un brouillon qui cite ses sources et dit que personne ne l'a relu. Un texte sans source ne peut donc pas être fusionné par erreur.

Avant toute diffusion, ce contrôle doit passer, c'est-à-dire que toutes les fiches doivent être relues :

```powershell
$env:CORTEGE_RELEASE_CHECK = '1'
flutter test test/content_catalog_test.dart
```

## Carte et paquet des organisateurs

L'appli ne télécharge jamais rien. L'organisateur prépare **un seul fichier** sur son ordinateur et l'envoie par n'importe quel moyen (messagerie, mail, clé USB) : l'événement signé (parcours, lieux, contacts) et, s'il le veut, la carte de la zone.

```bash
cd app
dart run tool/organizer/organizer.dart keygen --name "Collectif Eau" --out collectif.cle
dart run tool/organizer/organizer.dart event --key collectif.cle --in evenement.json --out evenement.cortege
```

`keygen` se fait une fois : il écrit la clé, l'empreinte à donner aux participants (de vive voix, sur l'affiche) et un QR facultatif. Le fichier `.cle` contient la clé secrète : ne le partage pas. Dans `evenement.json`, `"carte": true` joint une carte de la zone du parcours (ou `"carte": {"zone": [ouest, sud, est, nord], "zoom_max": 15}`). L'outil va chercher cette zone, et seulement elle, dans la carte du monde de [Protomaps](https://maps.protomaps.com/builds/), sans rien installer d'autre : le centre de Paris sur 4 km donne environ 5 Mo. Les données viennent d'OpenStreetMap, © les contributeurs d'OpenStreetMap, licence ODbL. Sans `carte`, le fichier ne fait que quelques Ko et le parcours et les lieux s'affichent sur un fond vide. Le fichier `evenement.json` décrit le parcours, les lieux (`eau`, `toilettes`, `rdv`, `dispersion`, `secours`, `juridique`, `sortie`, `info`) et les contacts ; un exemple complet est dans [ARCHITECTURE.md](ARCHITECTURE.md), section 17. Sous Windows, remplace `dart run tool/organizer/organizer.dart` par `flutter test tool/organizer/runner.dart --dart-define=ORG_ARGS="..."` (voir le fichier). L'outil de l'organisateur est le seul morceau du dépôt qui parle au réseau, sur l'ordinateur de l'organisateur, jamais dans l'appli.

Côté participant : ouvrir le fichier avec Cortège depuis la messagerie ou le gestionnaire de fichiers (ou « Organisation », « Importer un événement »). L'appli montre ce que contient le fichier et l'organisateur qui l'a signé. Si c'est la première fois, elle affiche l'empreinte de sa clé en grand : la comparer avec celle que l'organisateur a donnée, puis « Faire confiance et importer ». La carte jointe n'est acceptée que si elle a exactement l'empreinte que l'événement signé annonce. Elle est chiffrée sur le téléphone et disparaît avec l'effacement automatique. Scanner le QR de l'organisateur reste possible, et reste la méthode la plus sûre.

Limites : un événement prouve qui l'a écrit, pas que ce qu'il dit est juste. Sans comparaison de l'empreinte, un faux organisateur peut se faire accepter. Il n'y a pas de révocation d'une clé d'organisateur : il faut la retirer de la liste sur chaque téléphone. L'événement ne se relaie pas encore par le maillage.

## Partager l'appli de téléphone à téléphone

« Partager l'appli » (écran d'accueil) copie le fichier d'installation de l'appli et ouvre la feuille de partage d'Android (Bluetooth, Quick Share, clé USB). Le coffre, les groupes et les messages n'y sont pas. L'écran montre une empreinte courte du fichier : la personne qui l'installe voit la même dans son propre « Partager l'appli ». Ce n'est pas une preuve d'authenticité, seulement un moyen de voir que deux fichiers sont identiques : ne reçois l'appli que de quelqu'un en qui tu as confiance. L'autre personne doit autoriser l'installation depuis la source choisie. Voir la section 19 de [ARCHITECTURE.md](ARCHITECTURE.md) pour les limites.

## Construire

Il faut Flutter 3.41 ou plus, le SDK Android (NDK compris), Java 17 ou plus. Sous Windows, `make` et Git Bash doivent être dans le `PATH` pour compiler libsodium pour Android. Le `bash` de WSL est refusé : ajoute `C:\Program Files\Git\bin` à la fin du `PATH` pour que Git Bash soit trouvé. La première compilation Android prend environ dix minutes, le temps de construire libsodium.

```bash
cd app
flutter pub get
flutter test
flutter build apk --debug
```

### Lancer les tests sous Windows

Le hook qui compile libsodium sur le PC bute sur deux choses : il appelle une option que MSBuild 16 (Visual Studio 2019 Build Tools) n'a pas, et il plante sur les accents quand Windows n'est pas réglé en anglais. Le script `tool/windows/prepare_libsodium.ps1` contourne les deux. À lancer une fois après `flutter pub get`, et après chaque `flutter clean` :

```powershell
cd app
powershell -File tool\windows\prepare_libsodium.ps1
$env:MSBUILDDISABLENODEREUSE = '1'
flutter test
```

Les builds Android ne passent pas par là.

## Contribuer et signaler une faille

Les règles qu'on ne change pas, comment tester et comment aider sur les fiches sont dans [CONTRIBUTING.md](CONTRIBUTING.md). Une faille se signale en privé, comme décrit dans [SECURITY.md](SECURITY.md). Pour relire le code, [AUDIT.md](AUDIT.md) dit où regarder.

## Comment ce code a été écrit

Le code, les tests et les fiches ont été écrits avec l'aide d'un assistant d'intelligence artificielle (Claude, d'Anthropic), sous la direction et avec les essais sur téléphone d'une personne. Aucune fonction d'intelligence artificielle n'est dans l'appli : elle ne contacte aucun service. Comme aucune personne extérieure n'a encore relu ce code, ne le prends pas pour sûr sur la foi de ce dépôt : lis-le.

## Licence

GPL-3.0, texte complet dans [LICENSE](LICENSE).
