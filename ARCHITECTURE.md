# Cortège: architecture

Statut: décisions 1 à 6 validées, vérification des bibliothèques faite (section 12). Aucune ligne de code n'est écrite. Chaque décision porte son état : **validée** ou **à valider**.

## Décisions

| # | Sujet | État |
|---|-------|------|
| 1 | Stack : Flutter pour l'UI et la logique, code natif Kotlin et Swift pour le transport | validée |
| 2 | Limites d'iOS en arrière-plan acceptées, Android comme épine dorsale du maillage | validée |
| 3 | Confidentialité persistante complète en binôme, partielle en groupe | validée |
| 4 | Code de contrainte : protège d'une inspection rapide, pas d'une analyse forensique | validée |
| 5 | Alerte blessé : canal medic dédié, position grossière (voir section 8) | validée, révisée |
| 6 | Carte : tuiles OSM préparées à l'avance depuis un extrait, pas de téléchargement en direct | validée |
| 7 | Identifiant de service BLE dérivé d'un secret d'événement partagé par QR, pas un identifiant fixe (voir sections 12 et 14) | validée |

## 1. Stack

- **Dart (Flutter)** : interface, fiches droits et secours, logique du maillage (dédup, TTL, fragmentation), stockage chiffré, effacement automatique, verrouillage.
- **Kotlin et Swift** : uniquement la couche transport. BLE central et périphérique en même temps, advertising, GATT, Wi-Fi Aware / Wi-Fi Direct sur Android. Exposée à Dart par des platform channels.
- **libsodium** : toute la crypto, appelée depuis Dart via un binding. Aucune primitive maison.
- **Pourquoi** : le transport doit être natif de toute façon. Flutter évite d'écrire deux fois l'UI dense et le contenu, ce qui compte pour un projet open source tenu par peu de monde. Le prix : une frontière Dart/natif à bien cadrer, et le moteur Flutter comme dépendance de plus à auditer.

## 2. Transport : ce qui marche vraiment

| Liaison | Technologie | Remarque |
|---------|-------------|----------|
| Android vers Android | BLE, plus Wi-Fi Aware ou Wi-Fi Direct pour le débit | Wi-Fi dépend du matériel, BLE seul reste le minimum garanti |
| iOS vers iOS | BLE | Multipeer Connectivity exclu du MVP : Apple seulement, second protocole |
| iOS vers Android | BLE uniquement | Fiable seulement quand l'app iOS est au premier plan |

Il n'existe pas d'API publique de Wi-Fi Direct ou Wi-Fi Aware sur iOS compatible avec Android. Le canal haut débit est donc Android vers Android.

### Limites d'iOS en arrière-plan (à afficher dans le README et dans l'app)

- App iOS en arrière-plan : l'advertising continue mais sans nom local, et les UUID de service passent dans une zone « overflow » que seuls des appareils Apple qui scannent cet UUID retrouvent. Un Android ne la voit pas.
- Le scan en arrière-plan exige un filtre par UUID, supprime les doublons et tourne à cadence réduite.
- App tuée par l'utilisateur : plus aucun relais. La restauration d'état de CoreBluetooth ne couvre que quelques cas.
- Conséquence : iPhone en poche, écran éteint = relais dégradé et quasi invisible pour Android. Pour que l'iPhone compte dans le maillage, l'app doit rester ouverte.
- Côté Android, l'advertising et le scan continus passent par un foreground service avec notification persistante.

## 3. Protocole du maillage

Inondation contrôlée avec déduplication. Pas de table de routage, pas de voisins mémorisés : moins d'état, moins de traces, et ça tient quand les gens bougent.

- Chaque message a un identifiant aléatoire, un TTL (7 par défaut) et un horodatage grossier.
- Un nœud rediffuse un message qu'il n'a jamais vu, puis l'inscrit dans un cache « déjà vu » à fenêtre temporelle.
- Tous les nœuds relaient, membres du groupe ou pas. Un relais extérieur transporte sans pouvoir lire.
- Fragmentation et réassemblage au-dessus du MTU négocié (de l'ordre de 180 à 500 octets utiles selon les appareils).
- Défenses : limite de débit par voisin, fenêtre anti-rejeu, plafond de TTL côté réception.

## 4. Format de message

Binaire et compact (batterie, MTU).

En-tête visible par tous les relais :

- version
- identifiant de message (aléatoire)
- TTL
- étiquette éphémère d'émetteur, renouvelée régulièrement
- étiquette de groupe : valeur dérivée de la clé de groupe et de la période en cours, qui change avec elle. Un membre filtre vite sans tenter un déchiffrement sur chaque message ; un non-membre n'en tire rien de stable.
- longueur de la charge utile

Charge utile, chiffrée et authentifiée (AEAD) :

- type : chat, check-in binôme, alerte blessé, paquet organisateur, accusé de réception
- horodatage grossier
- identité de l'émetteur et signature Ed25519
- contenu

Limite assumée : le TTL doit rester lisible par les relais et change à chaque saut, donc il ne peut pas être couvert par l'authentification. Un relais hostile peut le gonfler. Les récepteurs plafonnent le TTL et limitent le débit par voisin.

## 5. Crypto (libsodium)

- Messages : XChaCha20-Poly1305. Échange de clés : X25519. Signatures : Ed25519. Dérivation depuis un PIN : Argon2id. Dérivations internes : BLAKE2.
- **Groupes (QR)** : le QR contient la clé de groupe. Posséder le QR, c'est appartenir au groupe : modèle de confiance voulu, à expliquer à l'utilisateur. Chaque membre a une identité Ed25519 pour prouver l'origine des messages.
- **Binôme (2 à 4 personnes)** : clés publiques échangées par QR, canal chiffré par paire avec ratchet pour la confidentialité persistante.
- **Limite sur les groupes** : un ratchet de groupe asynchrone sur maillage perdu-retrouvé n'est pas livrable proprement au MVP. On fait une rotation régulière de la clé de groupe plus un effacement agressif, et on écrit que la confidentialité persistante du groupe est partielle.
- **Identifiants Bluetooth** : étiquettes applicatives renouvelées toutes les quelques minutes, en plus de la randomisation d'adresse des OS. Attention : sur iPhone l'advertising ne porte que le nom et des UUID de service, pas de données constructeur. Une étiquette tournante ne peut donc pas voyager dans l'advertising sur iOS, et l'UUID de service lui-même trahit la présence de l'app (décision 7, section 12).

## 6. Données au repos, code de contrainte, effacement

- Tout est chiffré sur disque. La clé vient du PIN (Argon2id) mélangé à un secret matériel, et ne vit qu'en mémoire.
- **Code de contrainte** : deux PIN, deux coffres. Le vrai PIN ouvre le coffre réel, le code de contrainte ouvre un coffre leurre vide et crédible. Aucun message d'erreur ne trahit l'existence du second. Limite : face à un adversaire outillé, la présence de deux emplacements chiffrés peut se détecter. C'est une protection contre une inspection rapide sous contrainte.
- **Effacement automatique** : sur mémoire flash, réécrire ne garantit rien (répartition d'usure). Le vrai mécanisme est l'effacement cryptographique : détruire la clé rend les données illisibles. On détruit la clé et on supprime les enregistrements. Délai par défaut 24 h, réglable, avec un effacement manuel d'urgence.

### Réalisation (étape a)

- Deux fichiers `v0.bin` et `v1.bin` de même taille (256 Kio de contenu rempli, plus sel, nonce et tag). Contenu : sel (16 octets), nonce (24), puis le contenu chiffré par XChaCha20-Poly1305. Aucun en-tête, aucune marque lisible. Le rôle réel ou leurre est écrit dans le contenu chiffré. Le vrai coffre prend le fichier 0 ou 1 au hasard à la création.
- Sans code de contrainte, le second fichier est du bruit aléatoire de la même taille, et son secret matériel existe quand même : l'absence d'un second coffre ne se lit ni dans les fichiers ni dans le Keystore.
- Clé du coffre = BLAKE2b(Argon2id(PIN, sel), clé = secret matériel de l'emplacement). Un secret de 32 octets par emplacement, chiffré par une clé AES-GCM du Keystore Android (StrongBox si présent). Le déverrouillage essaie toujours les deux emplacements, pour que le temps de réponse ne distingue pas le vrai code du code de contrainte.
- Code : 6 à 12 chiffres, suites et répétitions refusées, pavé numérique maison (pas de clavier système).
- Effacement automatique : un enregistrement est périmé quand `maintenant >= création + durée` ou quand son échéance propre est passée. Balayage à l'ouverture, au retour au premier plan, et chaque minute appli ouverte. Raccourcir la durée efface tout de suite ce qui dépasse.
- Tout effacer : détruit les secrets du Keystore d'abord (coffre illisible immédiatement), puis supprime les fichiers. Geste : garder le doigt appuyé trois secondes.
- Verrouillage automatique 30 secondes après le passage en arrière-plan. Captures d'écran et miniatures bloquées (`FLAG_SECURE`).

### Limites connues de l'étape a

- ~~Rotation de clé absente~~ : faite le 23 octobre 2026, voir « Renouvellement du secret matériel » plus bas. Avant, retirer un enregistrement ne garantissait pas que d'anciennes versions du fichier, restées dans la mémoire flash, soient illisibles : elles se déchiffraient avec la même clé.
- ~~Pas de limitation des essais de code~~ : faite le 22 octobre 2026 (voir plus bas, « Limite des essais »). Cinq essais, puis 30 secondes, 1 minute, 5 minutes, 15 minutes, puis 1 heure entre deux essais, sans jamais effacer.
- **Paramètres Argon2id mesurés le 23 octobre 2026, inchangés.** Valeurs : 3 passes, 64 Mio. Le déverrouillage complet (deux dérivations en parallèle) prend **160 ms sur le HONOR**, bien en dessous de l'objectif d'une seconde. Deux raisons de ne rien changer maintenant. D'abord, face à un code de 6 chiffres (un million de possibilités), rendre chaque essai quelques fois plus lent change peu pour quelqu'un qui dispose de plusieurs machines : ce qui protège vraiment est le secret gardé par le Keystore, la limite des essais et un code plus long. Ensuite, les réglages ne sont écrits nulle part dans les fichiers du coffre (pas d'en-tête, voulu) : les changer demande de rouvrir chaque coffre avec les anciens réglages, donc une migration. À reprendre avec un téléphone d'entrée de gamme, qu'on n'a pas, et avant toute diffusion. Conseil à donner dans l'appli : un code de 8 chiffres ou plus.
- **Balayage en arrière-plan absent.** Appli fermée plus longtemps que la durée choisie, rien n'est effacé avant la prochaine ouverture.
- **Horloge du téléphone.** Les échéances reposent sur l'heure du téléphone : la reculer prolonge la vie des données.
- **Pas d'iOS.** Le secret matériel est écrit pour le Keystore Android seulement. Sur iOS l'appli refuse de créer un coffre.
- **Positions** : en mémoire vive seulement, jamais écrites, jamais d'historique.

### Renouvellement du secret matériel (23 octobre 2026)

- **Principe.** La clé du coffre vient du code (Argon2id) et du secret gardé par le Keystore. Quand quelque chose est effacé, l'appli remplace le secret de l'emplacement par un nouveau (avec une nouvelle clé Keystore, StrongBox si le téléphone en a), réécrit le coffre avec la clé qui en découle, puis détruit l'ancien secret. Une vieille copie du fichier, restée dans la mémoire flash, ne se déchiffre plus, même avec le bon code : il n'existe plus rien pour la lire. Pour cela la session garde en mémoire le résultat d'Argon2id (même sensibilité que la clé du coffre) : changer de secret ne redemande pas le code.
- **Quand.** Après chaque effacement de l'effaceur (messages, groupes, binômes, organisateurs périmés, fin d'événement), après avoir quitté un groupe, un binôme ou l'événement, et après avoir oublié un organisateur. Au plus une fois toutes les dix minutes (la création d'une clé Keystore coûte) ; une demande trop proche est gardée et faite par le balayage suivant. Au déverrouillage, si l'appli est restée fermée au-delà de la durée d'effacement, l'effacement et le renouvellement ont lieu tout de suite.
- **Coupure à n'importe quel instant.** Un emplacement peut garder deux secrets (générations 0 et 1) le temps de l'opération. Ordre : le nouveau s'ajoute à l'ancien (le fichier est encore sous l'ancien), le fichier est réécrit sous le nouveau (renommage atomique), l'ancien est détruit. À l'ouverture, le plus récent est essayé en premier, puis l'autre (Argon2id ne se calcule qu'une fois) ; celui qui ouvre est gardé, l'autre détruit. Les deux emplacements gardent un secret, même le leurre ou le bruit : rien ne se lit depuis l'extérieur. Un secret au format d'avant (génération 2, sans compteur) est lu tel quel et disparaît au premier renouvellement.
- **Écritures en même temps.** Pendant un renouvellement, une écriture demandée attend la nouvelle clé : un fichier scellé avec l'ancienne et écrit après le nouveau deviendrait illisible dès que l'ancien secret est détruit.
- **Verrouillage en cours de route.** Se servir d'une clé détruite plante l'appli (trouvé par un test : arrêt brutal du processus). Chaque usage vérifie donc que la session n'est pas verrouillée juste avant, et une écriture sur un coffre verrouillé lève une erreur au lieu de planter.
- **Visible dans les réglages** : « Dernier renouvellement : il y a X min », ou « Un renouvellement attend son tour ».
- **Limites.** Cela protège les vieilles copies du fichier du coffre ; cela ne dit rien des autres endroits où des traces pourraient survivre (sauvegarde de l'appli désactivée ; journal du système ; mémoire vive d'un téléphone allumé). Un renouvellement raté est retenté mais reste invisible hors des réglages. Le matériel du téléphone n'est pas auditable : on suppose que supprimer une clé du Keystore la détruit.
- **Tests** : 17 (ouverture et données gardées, copie d'avant illisible mais lisible avec l'ancien secret rendu, effacement automatique, rythme, reprise par l'effaceur, trois coupures simulées, écriture pendant le renouvellement, verrouillage en route, deux demandes d'un coup, changement de code, leurre, texte des réglages).

### Limite des essais (22 octobre 2026)

- **Principe** (`lib/vault/attempt_limiter.dart`) : cinq essais de code ratés sont libres. Au cinquième échec, l'écran de code se fige avec un décompte (« Trop d'essais. Réessaie dans 30 s. »). Les échecs suivants imposent 1 minute, 5 minutes, 15 minutes, puis 1 heure entre deux essais. Un code juste, le vrai ou celui de contrainte, remet le compte à zéro. Rien n'est effacé : une limite qui efface permettrait à un enfant ou à un passant de détruire tes données.
- **Le compte est écrit avant de vérifier le code** (fichier `t.bin` de 16 octets dans le dossier de l'appli, nombre d'échecs et heure de fin d'attente). Fermer l'appli en plein essai ne le rejoue pas gratuitement. Un secret matériel disparu (téléphone réinitialisé) n'est pas compté comme un essai raté.
- **Même attente pour tous les codes ratés, et même pour un code juste pendant l'attente** : rien ne dit s'il existe un second coffre. L'attente s'applique aussi derrière l'écran de code, quand le coffre tourne déjà en mémoire.
- **Reculer l'horloge** ne raccourcit pas l'attente (elle est plafonnée à ce qui était prévu) et ne la rallonge pas. **L'avancer** la raccourcit : l'heure du téléphone n'est pas de confiance.
- **Ce que cela ne protège pas** : quelqu'un qui lit et modifie les fichiers de l'appli (téléphone débloqué au niveau du système) peut remettre le compteur à zéro. Il se heurte alors à Argon2id et au secret du Keystore, qui ne dépendent pas du compteur. Le compteur freine surtout celui qui tape des codes sur l'écran.
- **Tests** : 11 (barème, redémarrage, horloge reculée, fichier abîmé, coffre avec ou sans code de contrainte, secrets disparus, effacement total, écran de code avec décompte).

### Code oublié (24 octobre 2026)

- **Principe.** Sous le clavier de l'écran de code, « Code oublié ? » ouvre un écran qui dit que le code ne se retrouve pas et propose « Tout effacer » (appui de 3 secondes, comme dans les Réglages). C'est le même effacement : secrets matériels détruits d'abord, puis fichiers du coffre, cartes, fichiers reçus et compteur d'essais. L'appli retombe sur la création du coffre. Avant ce chemin, l'appli disait « il faut tout effacer » sans offrir de moyen d'y arriver sans le code.
- **Pendant l'attente.** Le chemin reste ouvert quand le clavier est figé après trop d'essais ratés : celui qui a oublié son code n'attend pas une heure, et l'effacement remet l'attente à zéro.
- **Pourquoi ce n'est pas une faille.** Effacer ne donne rien à celui qui tient le téléphone, tout est détruit, et il pouvait déjà vider les données de l'appli depuis Android. Ce qui change, c'est qu'une personne qui a oublié son code a une issue claire. Contrepartie : un passant qui tient ton téléphone peut détruire tes données depuis l'écran de code, comme il le pouvait depuis Android.
- **Navigation.** L'écran « Code oublié » ne reste pas empilé après l'effacement : les écrans empilés se ferment à tout changement d'état qui sort du coffre ouvert, pas seulement au verrouillage.
- **Tests** : 5 (écran et texte, « Retour » qui ne touche à rien, appui trop court sans effet, effacement complet puis nouveau départ avec ancien code et code de contrainte refusés, chemin ouvert pendant l'attente avec compteur remis à zéro). Un test échoue si la règle de fermeture des écrans revient à l'ancienne.
- **Essai sur téléphone (HONOR, 24 octobre 2026)** : le bouton, « Retour », l'appui court sans effet et l'appui de 3 secondes qui ramène à la création du coffre : essai concluant. Pas encore essayé sur le OnePlus (mémoire pleine, installation impossible pour l'instant).

## 7. Mode binôme

Réalisé à l'étape d, voir la section 15.

Check-in périodique entre 2 et 4 personnes appairées. Alerte si un membre ne répond plus ou sort de portée. « Sort de portée » signifie ici « on ne l'entend plus dans le maillage », pas « position connue ». Aucune position n'est conservée.

## 8. Alerte blessé et rôle medic

Réalisé à l'étape d, voir la section 15 (la clé publique du canal voyage dans les invitations de groupe et de binôme, la clé secrète seulement dans le QR des medics).

Cette section corrige la version de la proposition précédente : limiter l'alerte au groupe de l'émetteur contredit la fonction, puisque les medics ne sont pas forcément dans son groupe.

- Les medics partagent une **clé de canal medic**, distribuée par QR par un collectif de medics ou par les organisateurs. Activer le rôle « medic » dans les réglages charge cette clé.
- L'alerte est chiffrée pour ce canal, avec une position **grossière** (ordre de 100 à 200 m) et le type de besoin.
- La position précise part ensuite, en point à point, vers le medic qui répond.
- Risque à connaître : quiconque obtient le QR medic lit toutes les alertes. La parade est de ne le distribuer qu'à des gens connus, et de pouvoir faire tourner la clé.
- Alternatives écartées : alerte limitée au groupe (les medics ne la reçoivent pas), diffusion en clair dans tout le maillage (donne la position à un relais hostile).

## 9. Infos des organisateurs et carte

- Paquet signé Ed25519 par l'organisateur : parcours déclaré, points d'eau, toilettes, rendez-vous, dispersion. Horodaté, avec expiration. La clé publique de l'organisateur arrive par QR. L'app vérifie la signature avant d'afficher quoi que ce soit.
- Import : fichier (décidé le 21 octobre 2026) ; le relais dans le maillage, fragmenté, viendra plus tard.
- Carte : tuiles vectorielles préparées avant l'événement à partir d'un extrait de données OpenStreetMap, stockées sur l'appareil. On ne télécharge pas en masse depuis le serveur de tuiles public d'OpenStreetMap, dont la politique d'usage l'interdit. Attribution OpenStreetMap affichée sur la carte. Aucune requête réseau pendant l'usage. Le rendu se fait par un moteur écrit pour l'appli, en Dart, et non par MapLibre (décidé le 21 octobre 2026) : voir la section 17.

Réalisé à l'étape e, voir la section 17.

## 10. Modèle de menace

Couverts :

- Surveillance réseau (IMSI catcher, opérateur) : l'app n'émet aucune requête réseau.
- Saisie de l'appareil : chiffrement au repos, code de contrainte, effacement automatique, aucune position stockée.
- Pistage par Bluetooth : étiquettes renouvelées, pas d'identifiant stable.
- Relais hostile sans la clé de groupe : peut relayer et faire de l'analyse de trafic, ne peut pas lire. Rejeu et saturation limités.
- Chaîne d'approvisionnement : code ouvert, dépendances minimales, builds reproductibles visés.

Hors périmètre :

- Téléphone déjà compromis par un logiciel espion.
- Membre du groupe qui trahit : inhérent au « QR = accès ».
- Déniabilité parfaite du code de contrainte face à un labo forensique.
- Corrélation temporelle ou physique entre appareils : atténuée, pas supprimée.
- Un relais proche qui mesure la force du signal peut estimer qu'un appareil est là. Le renouvellement des étiquettes l'empêche de le suivre dans la durée, pas de le voir à l'instant.

## 11. Tests prévus

- **Crypto** : aller-retour AEAD, vecteurs connus, Argon2id, signatures valides et invalides, séparation stricte coffre réel et coffre leurre, rotation de clé de groupe.
- **Relais** : déduplication, respect du TTL, absence de boucle sur un graphe de maillage simulé, fragmentation et réassemblage, rejeu rejeté.
- **Effacement** : expiration par délai, destruction de clé qui rend les données illisibles, effacement du code de contrainte, effacement manuel.

## 12. Vérifications faites (18 octobre 2026)

Sources : pages pub.dev des paquets, documentation Apple, Android et OSMF. Ce qui n'a pas pu être confirmé est écrit « non confirmé ». Rien de non confirmé ne doit être tenu pour acquis.

### Crypto

- Binding retenu : `sodium` Dart, épinglé en 4.0.2+1 (libsodium 1.0.21 embarqué), Android et iOS. `sodium_libs` est déprécié, on ne l'utilise pas. La 4.1.2 existe mais n'a pas été retenue par la résolution de dépendances ; à réévaluer. libsodium est compilé à la demande par les build hooks de Dart (native assets).
- Confirmés disponibles et utilisés : XChaCha20-Poly1305, `crypto_pwhash`, BLAKE2b avec clé. Prévus pour la suite : `crypto_sign`, `crypto_box`, `crypto_scalarmult`, secretstream.
- **Argon2id explicite : confirmé à l'étape a.** L'API expose `CryptoPwhashAlgorithm.argon2id13`, et un test vérifie que la clé du coffre est bien BLAKE2b(Argon2id(PIN, sel)) avec ce paramètre. `crypto_pwhash` fait partie de l'API « sumo » : on initialise avec `SodiumSumoInit`.
- Les clés `SecureKey` vivent en mémoire native et doivent être libérées à la main, sinon elles fuient. Le code les libère au verrouillage et après chaque dérivation.
- Le paquet est jeune et sa couverture de l'API est incomplète. On épingle la version.
- Android : la compilation de libsodium passe par `bash` (Git Bash, pas WSL) et `make`. Sous Windows, `C:\Program Files\Git\bin` doit être dans le `PATH`, sinon le hook ne trouve que le `bash` de WSL et refuse. Vérifié : `flutter build apk --debug` réussit (environ dix minutes la première fois).
- Windows, pour lancer `flutter test` sur le PC : le hook appelle `msbuild /getProperty`, absent de MSBuild 16 (Visual Studio 2019 Build Tools), et plante sur les accents quand Windows n'est pas réglé en anglais. Contournement : `app/tool/windows/prepare_libsodium.ps1`. Un Visual Studio 2022 réglerait le premier problème.

### BLE

- `flutter_blue_plus` : rôle central uniquement. Écarté.
- `bluetooth_low_energy` 6.2.1 : gestionnaire central et gestionnaire périphérique, serveur GATT, négociation de MTU, Android et iOS. Une version 7 en préversion existe. Android minSdk 24 minimum. **Test du 18 octobre 2026 : les deux rôles en même temps fonctionnent sur Android** (résultats ci-dessous). Reste non testé : l'arrière-plan, l'écran éteint, trois téléphones ou plus, iOS.

Résultats du test à deux téléphones (un HONOR sous Android 16 et un OnePlus), avec un test jetable qui n'est pas dans ce dépôt :

- Chaque téléphone annonce un service et cherche les autres en même temps, puis se connecte dans les deux sens : deux connexions croisées entre les mêmes deux téléphones, stables pendant plus de deux minutes, avec envoi et réception d'un message toutes les 3 secondes dans chaque sens. Un seul échec, à l'arrêt volontaire du test.
- Découverte environ 0,4 seconde après le démarrage (signal -64 dBm, téléphones côte à côte). Connexion en 0,7 seconde. Lien prêt (MTU négocié, services découverts) en environ 3 secondes.
- MTU 517 sur les deux liens, écriture maximale de 512 octets par message. Aller-retour d'une écriture avec accusé : 60 à 125 ms.
- **Un même téléphone apparaît sous deux adresses Bluetooth différentes** : celle qu'il montre quand il annonce, et celle qu'il montre quand il se connecte comme central. Impossible donc d'identifier un voisin par son adresse BLE. L'identité d'un voisin doit être un identifiant de l'appli, dans les messages (confirme la section 4).
- Les événements de connexion du côté périphérique incluent aussi nos propres connexions sortantes : ne pas s'en servir pour compter les connexions entrantes.
- L'HONOR n'écrit rien dans les journaux `adb` en version release : pour lui, on lit les résultats à l'écran de l'appli ou depuis l'autre téléphone.
- `ble_peripheral` 2.4.0 : périphérique seulement, dernière publication il y a 22 mois. Écarté.
- Le BLE ne fonctionne pas sur émulateur : téléphones réels obligatoires.

### Advertising : un problème nouveau

- Sur Apple, l'advertising ne porte que le nom et des UUID de service, pas de données constructeur. Mon idée d'étiquettes tournantes dans l'advertising ne tient donc pas sur iPhone.
- En arrière-plan, iOS ignore le nom local et range les UUID dans une zone « overflow » que seuls des appareils iOS qui scannent explicitement ces UUID peuvent lire. Le format n'est pas documenté, la remise est « au mieux » et la fréquence d'advertising peut baisser. Cela confirme la section 2.
- Pour qu'un scan retrouve l'app, il faut un UUID de service. S'il est fixe, n'importe qui avec un scanner BLE peut compter les téléphones qui font tourner Cortège dans une foule.
- Décision 7, deux options :
  - **Fixe et public** : simple, tout le monde se découvre, mais l'app est détectable par tous.
  - **Dérivé d'un secret d'événement** : l'UUID change par période et se calcule à partir d'un secret présent dans les QR de groupe et le paquet des organisateurs. Quelqu'un sans le secret ne reconnaît pas l'app. En contrepartie, seuls ceux qui partagent le secret se découvrent entre eux, donc un téléphone sans QR ne relaie pas.
  - Recommandation : la seconde, parce que le traçage des manifestants est la menace centrale. Elle coûte de la couverture du maillage, à dire clairement dans l'app.

### Android

- Advertising classique : 31 octets, plus 3 d'indicateurs si connectable. Un UUID de 128 bits en prend 18. L'advertising étendu dépend du téléphone (`getLeMaximumAdvertisingDataLength`). Non confirmé pour les modèles visés.
- Foreground service : depuis Android 14, un type est obligatoire. Pour le BLE, `connectedDevice` avec la permission `FOREGROUND_SERVICE_CONNECTED_DEVICE`, plus `BLUETOOTH_SCAN` (avec `neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` et la permission de notification pour afficher la notification persistante. Ces détails viennent de sources tierces : à relire sur developer.android.com avant d'écrire le manifeste.
- Nombre de connexions GATT simultanées et MTU réellement obtenus : non trouvés, à mesurer.
- Wi-Fi Aware : disponible depuis l'API 26, mais dépend du matériel et du firmware. On teste `FEATURE_WIFI_AWARE` puis `isAvailable()`, et la disponibilité peut disparaître à tout moment, par exemple pendant un partage de connexion ou du Wi-Fi Direct. C'est un bonus, jamais une exigence.

### Carte

- `maplibre_gl` 0.24.1 (Flutter 3.29 minimum) : PMTiles pris en charge par le protocole `pmtiles://`, régions hors ligne listées. MBTiles n'est pas natif : copie de fichier ou conversion. On part sur PMTiles. Non confirmé : le fonctionnement hors ligne réel sur Android et iOS, à tester à l'étape e.
- Politique d'OpenStreetMap : le service de tuiles public ne doit pas servir au préchargement hors ligne, et les violations sont bloquées sans préavis. On produit nos propres tuiles à partir d'un extrait de données OpenStreetMap. L'attribution OpenStreetMap reste affichée sur la carte.

### Machine de développement

- Flutter 3.41.5 et Dart 3.11.3 : prêts. SDK Android 36, NDK présents.
- `make` 4.4.1 installé (winget, `ezwinports.make`).
- Un téléphone Android est détecté par `adb` mais n'était pas autorisé au dernier contrôle (débogage USB à confirmer sur l'écran du téléphone).
- Pas de Mac : on ne peut pas compiler pour iOS depuis cette machine. Bloquant pour l'étape f seulement.

## 13. Fiches droits et secours (étape b)

- Un fichier texte par fiche, embarqué comme asset (`app/assets/content/`). Aucune requête réseau. Format et règles en tête de `app/lib/content/fiche.dart`.
- **Aucun texte juridique ou médical inventé.** Jusqu'au 24 octobre 2026, les fiches ne contenaient que des titres de section et des lignes `? ` : des questions auxquelles la fiche devra répondre, affichées « À RÉDIGER ». Les rubriques viennent de la spec : contrôle d'identité, fouille, garde à vue, contacts utiles ; numéros d'urgence, lacrymogènes, chaleur, malaise, blessure. Depuis, elles contiennent des brouillons sourcés (voir plus bas), jamais des textes de mémoire.
- Les numéros d'urgence 15, 17, 18 et 112 avaient été vérifiés sur service-public.gouv.fr et gendarmerie.interieur.gouv.fr le 18 octobre 2026. Ils portent quand même le bandeau « à faire valider ».
- Bandeau jaune plein sur chaque écran tant que `statut: a_valider` : « À FAIRE VALIDER PAR UN JURISTE » (droits) ou « À FAIRE VALIDER PAR DES SECOURISTES » (secours). Une fiche validée affiche « Relu par ... » et exige `relu_par`.
- Un test interdit tout paragraphe, point de liste ou avertissement dans une fiche non relue, sauf si c'est un brouillon sourcé (voir plus bas). Un second test, réservé à la diffusion (`CORTEGE_RELEASE_CHECK=1`), échoue tant qu'une fiche n'est pas relue.
- Les contacts d'aide juridique locale (permanence, avocats) sont des emplacements à remplir. Ils viendront du paquet des organisateurs (étape e), pas du code.
- Les mêmes fiches s'affichent dans le vrai coffre et dans le leurre : ce sont des contenus publics.
- Pas encore fait : appeler un numéro d'un appui (il faudrait un intent de composition natif, sans permission), et rechercher dans les fiches.
- **Brouillons sourcés du 24 octobre 2026.** Les neuf fiches ont été rédigées par l'assistant à partir de sources officielles lues ce jour-là (service-public.gouv.fr, Légifrance, ministère de la Justice, Croix-Rouge, Assurance maladie, INRS, Manuel MSD), chacune avec sa liste de sources, ses lignes `!` « à faire vérifier » et 8 questions laissées ouvertes sur 61 faute de source. Aucun juriste ni secouriste ne les a relus. D'abord gardés hors de l'appli, ils y sont entrés le même jour sur décision de l'utilisateur, prise en connaissance de cause (« je comprends que personne ne les a relus »).
- **La règle a changé, elle n'a pas disparu.** Une fiche non relue peut contenir du texte seulement si elle porte `redaction: brouillon_source` dans son en-tête. Alors : le bandeau jaune « À FAIRE VALIDER PAR … » reste, suivi de « Brouillon écrit par un assistant d'après des sources officielles. Personne ne l'a relu. Les sources sont en bas de la fiche. » ; la liste de la rubrique dit « Personne n'a encore relu ces fiches » ; un test vérifie que le brouillon cite ses sources (`https://`), a une section « Sources », dit « Aucune relecture humaine à ce jour », tutoie et n'a pas de tiret long ; le programme refuse de lire une fiche relue qui garde la mention ; le test de diffusion (`CORTEGE_RELEASE_CHECK=1`) échoue tant qu'une fiche n'est pas relue, donc aucun brouillon ne peut partir dans une version diffusée. `RELECTURE-DES-FICHES.md` (à la racine) dit qui doit relire, ce qui reste douteux, comment valider une fiche et comment revenir en arrière.

## 14. Messagerie maillée (étape c)

### Ce qui est construit

- **Groupes par QR.** Le QR contient le nom du groupe, la clé du groupe (32 octets) et le secret d'événement (32 octets), soit environ 150 caractères. Posséder le QR, c'est appartenir au groupe : quiconque le photographie peut lire et écrire. Un téléphone est dans un seul événement à la fois ; tous les groupes d'un événement partagent le même secret, c'est ce qui les fait se retrouver. Scanner le QR d'un autre événement est refusé tant qu'on a des groupes.
- **Identifiants Bluetooth (décision 7).** L'identifiant annoncé est calculé à partir du secret d'événement et change toutes les 15 minutes. On cherche la période précédente, courante et suivante pour absorber les écarts d'horloge. Un passant avec un scanner ne reconnaît ni l'appli ni un téléphone dans la durée. Le service GATT et la « boîte de réception » ont un identifiant propre à l'événement mais stable (le changer couperait les connexions) : on ne le voit qu'après s'être connecté.
- **Trame.** Version, TTL, étiquette de groupe (16 octets, change toutes les heures), nonce, contenu chiffré XChaCha20-Poly1305. Le contenu porte le type, l'heure, la clé de signature publique de l'expéditeur, son pseudo, le texte et une signature Ed25519 qui couvre aussi l'étiquette (impossible de rejouer un message dans un autre groupe). Le contenu est rempli par blocs de 64 octets : la longueur ne trahit pas la longueur du texte. Texte limité à 300 octets, pseudo à 24.
- **Relais.** Inondation avec dédoublonnage par empreinte du chiffré, TTL de 7 plafonné à la réception, limite de 60 trames par 10 secondes et par voisin, cache « déjà vu » d'une heure. Les relais hors du groupe transportent sans lire. Une trame de nos groupes qui échoue au déchiffrement ou à la signature n'est jamais rediffusée. Les messages de plus de la durée d'effacement, ou datés de plus de 10 minutes dans le futur, sont refusés.
- **Radio.** Chaque téléphone est périphérique (il annonce et reçoit) et central (il cherche et écrit) en même temps, comme le test l'a montré. Trames découpées en morceaux de la taille d'écriture négociée (jusqu'à 512 octets) avec un préfixe de longueur sur 2 octets, écrites une trame à la fois par voisin. Au plus 4 connexions sortantes. Écriture avec accusé, donc dans l'ordre.
- **Identité.** Chaque groupe a sa propre paire de clés de signature, créée à l'entrée dans le groupe : un membre n'est pas reliable d'un groupe à l'autre. Le pseudo n'est pas vérifié ; deux membres peuvent avoir le même, d'où l'étiquette de 6 caractères tirée de la clé, affichée à côté.
- **Données.** Groupes (avec leurs clés), secret d'événement et messages vivent dans le coffre chiffré. Un message disparaît à la fin de la durée d'effacement, comptée depuis son envoi. Un groupe sans activité pendant la durée d'effacement disparaît avec ses clés, et le dernier groupe emporte le secret d'événement : la radio s'éteint.
- **Verrouillage à deux niveaux.** Premier niveau, l'écran de code : après 30 secondes hors de l'appli (réglable de 30 secondes à 15 minutes), l'interface demande le code et ne montre plus rien, mais la clé du coffre et le maillage restent en mémoire. Les messages reçus pendant ce temps sont enregistrés dans le coffre. Second niveau, la fermeture complète : après une durée réglable (aucune, 15 minutes, 1 heure par défaut, 4 heures) comptée depuis l'écran de code, la clé est détruite et le maillage s'arrête. « Aucun » fait coïncider les deux niveaux, comme avant. Le bon code derrière l'écran réutilise le coffre en mémoire sans couper la radio ; le code de contrainte ferme le vrai coffre à l'instant et ouvre le leurre. Les durées sont recomptées avec l'horloge au retour dans l'appli, car les minuteurs peuvent dormir. Un service au premier plan avec une notification neutre (sans le nom de l'appli, cachée sur l'écran verrouillé) garde l'appli en vie quand l'écran s'éteint.
- **Lecture des QR** dans l'appli (caméra Flutter et décodeur Dart `zxing2`), sans service Google. Les permissions que ces bibliothèques ajoutent d'office (réseau, micro, stockage) sont retirées du manifeste.

### Limites connues

- **Clés en mémoire derrière l'écran de code.** Pendant la durée choisie, quelqu'un qui saisit le téléphone allumé et sait lire sa mémoire pourrait récupérer les clés du coffre et des groupes. L'écran de code ne protège que d'un regard ou d'un essai à la main. C'est le prix de la réception dans la poche, et le réglage « Aucun » le supprime. Après la fermeture complète, le maillage est arrêté : un relais seul avec le secret d'événement, sans les clés de groupe, n'est pas écrit.
- **Pas de stockage ni d'accusé de réception.** Un message envoyé quand personne n'est à portée est perdu. Un téléphone qui rentre dans la zone ne reçoit pas ce qu'il a manqué.
- **Clé de groupe fixe.** Pas de rotation de clé ni de confidentialité persistante pour les groupes : qui obtient la clé plus tard et a enregistré la radio avant peut tout relire. À traiter avec la rotation de clé de l'effacement (section 6).
- **Connexions limitées.** Quatre voisins en sortie, plus ceux qui se connectent à nous. En foule dense, le maillage peut se découper en îlots. À mesurer avec plus de deux téléphones.
- **Batterie non mesurée.** La recherche tourne en continu tant que le maillage est actif.
- **Analyse de trafic.** Un observateur voit des trames de tailles semblables, une étiquette de groupe qui change chaque heure, et des téléphones qui émettent. Il ne lit rien. Il peut estimer qu'un téléphone est proche grâce à la puissance du signal.
- **Trois téléphones ou plus, iOS, appli en arrière-plan prolongé : non testés** (voir la section 12 et les essais sur téléphone).

### Ce que l'essai sur téléphone a montré (18 octobre 2026, HONOR et OnePlus)

- **Lecture du QR.** Première version muette : la lecture partait dans un autre isolate avec une fermeture qui emportait tout l'écran, ce que Dart refuse, et l'erreur était avalée. Corrigé avec une fonction hors de toute classe. Les tests montrent qu'un QR de 49 carrés demande 4 à 6 pixels par carré pour être lu malgré le flou : la caméra passe en 1920 par 1080, le lecteur essaie trois méthodes de seuil, l'écran qui affiche le QR monte au maximum de luminosité, et un bouton copier/coller sert de secours. Le scan fonctionne.
- **Démarrage de la radio.** Sur le OnePlus, redemander les autorisations Bluetooth alors qu'elles étaient déjà accordées ne recevait jamais de réponse : le maillage restait bloqué sur « démarrage ». L'appli ne les demande plus que si elles manquent, chaque étape de la radio a un délai maximal, et un Bluetooth éteint est réessayé toutes les 15 secondes. Une permission refusée n'est pas redemandée en boucle.
- **Délais mesurés.** Un voisin est vu moins d'une seconde après le démarrage de la recherche, le lien est prêt (connexion, MTU 517, services découverts) environ 2 à 3 secondes plus tard, écriture maximale de 512 octets.
- **Messages.** Envoyés et reçus dans les deux sens entre les deux téléphones, par Bluetooth, sans réseau.
- **Écran éteint (OnePlus, 2 minutes, derrière l'écran de code).** Les messages écrits depuis l'autre téléphone sont arrivés. Le premier essai avait échoué parce que le délai de verrouillage de l'époque (30 secondes) arrêtait le maillage : d'où le verrouillage à deux niveaux.
- **Notification du service.** Sur le OnePlus, l'autorisation de notifications n'avait pas été accordée : Android cache alors la notification « Service actif », mais le service au premier plan tourne quand même (vérifié avec `dumpsys` : `isForeground=true`) et l'appli reste en vie. Le service apparaît dans la liste des applis actives d'Android.
- **Quitter un groupe.** Fonctionne ; les autres membres gardent leurs copies des anciens messages jusqu'à la fin de leur durée d'effacement (pas d'effacement à distance).
- **Pas encore essayé :** éloignement et retour à portée, écran éteint plus longtemps qu'une demi-heure (les gestionnaires de batterie des constructeurs tuent les applis en arrière-plan), trois téléphones ou plus.

### Tests

- 50 tests de protocole et de relais sur réseau simulé (chaînes, anneaux, grilles, graphes complets), 24 tests du contrôleur avec une fausse radio (dont la relance automatique), 8 tests de QR, 4 de l'interface des messages. Ils couvrent le chiffrement, le relais des messages et l'effacement, comme demandé.

## 15. Binôme et alerte blessé (étape d)

### Binôme

- **Appairage en face à face.** Chacun montre son code (QR « CORTEGEB1. ») à l'autre, qui le scanne. Le code porte l'identifiant du binôme, le secret d'événement, la clé de l'étiquette, le pseudo, la clé de signature publique de la personne, l'état courant de sa chaîne de clés et, si on la connaît, la clé publique du canal des medics. Celui qui crée le binôme est scanné par l'autre, puis scanne en retour. Un binôme tient au plus à quatre personnes ; quand une troisième rejoint, celui qui l'a scannée repasse la liste des proches aux autres (message « liste », renvoyé un check-in sur trois pour rattraper ceux qui l'ont manqué).
- **Une chaîne de clés par personne.** Chaque message d'un binôme part avec une clé neuve, tirée de la clé précédente par un hachage à sens unique (BLAKE2b avec étiquette), et la clé utilisée est détruite. Quelqu'un qui obtient la chaîne d'aujourd'hui ne relit pas les messages d'hier. Le nonce est l'index du message sur 4 octets suivi de 20 octets aléatoires. Le récepteur accepte de sauter jusqu'à 64 messages perdus et garde au plus 128 clés sautées pour les messages en retard. L'état de la chaîne n'avance qu'après vérification de la signature : une trame forgée ne fait pas avancer la chaîne. La signature doit venir de la personne dont la chaîne a servi (liaison clé de chaîne et clé de signature).
- **Check-in.** Un signe de vie part toutes les 5 minutes par défaut (2, 5, 10 ou 15 dans les réglages), le premier quelques secondes après le démarrage de la radio. Un bouton « Je vais bien » en envoie un tout de suite.
- **Silence.** Quelqu'un est signalé muet quand on n'a reçu aucun signe de lui depuis deux intervalles plus une tolérance de 30 secondes. L'appli prévient une fois quand il se tait (bandeau rouge, vibration), une fois quand il revient. Ce que ça veut dire : on n'entend plus rien de cette personne dans le maillage. Ça peut être un téléphone éteint, un Bluetooth coupé, une batterie vide, une personne plus loin que le maillage ne porte. L'appli ne sait pas où elle est.
- **Où ça vit.** Les binômes (clés comprises) sont dans le coffre et suivent l'effacement automatique. Les heures de dernier signe sont en mémoire seulement.

### Canal des medics et alerte blessé

- **Canal.** Un medic crée le canal : une paire de clés de chiffrement à clé publique (libsodium, `crypto_box_seal`). La clé publique voyage dans les invitations de groupe (version 2 du QR) et de binôme : tout le monde peut donc écrire une alerte, seuls les medics la lisent. La clé secrète n'est que dans le QR « CORTEGEM1. », que les medics se remettent en face à face. Les téléphones qui ne connaissent que la clé publique relaient les trames de ce canal sans les lire.
- **Alerte.** Type de besoin (blessure, malaise, gaz), position arrondie sur une grille de 0,002 degré (environ 200 m), une clé de réponse à usage unique et un identifiant d'alerte. Ni le pseudo ni le groupe n'y figurent. Chiffrée pour le canal, signée avec une clé éphémère à chaque alerte (pas de lien entre deux alertes d'une même personne). Un appui prolongé de 1,5 s déclenche l'envoi ; un double envoi sous 15 s est ignoré.
- **Réponse.** Un medic qui répond envoie son pseudo et une clé de réponse, chiffrés pour la clé de réponse de l'alerte. La personne voit « Mel arrive » et décide seule d'envoyer ou non sa position précise, chiffrée pour ce seul medic.
- **Où ça vit.** Les alertes, les réponses et les positions précises ne sont jamais écrites dans le coffre : elles vivent en mémoire, 2 heures au plus, et disparaissent au verrouillage complet. Les clés du canal des medics sont dans le coffre et partent avec les données de l'événement quand le rôle de medic reste inactif plus que la durée d'effacement.
- **Position.** Demandée au moment du signalement ou du partage, par le système Android (sans service Google). La permission n'est pas demandée avant. Aucune position n'est gardée, aucun historique.
- **Renvois.** Le maillage n'a ni stockage ni accusé de réception, et un envoi fait quand le voisin est hors de portée est perdu. Une alerte est donc rejouée (4, 8, 16, 32 puis toutes les 60 secondes) tant qu'aucun medic n'a répondu, au plus 30 minutes. La réponse d'un medic est rejouée (mêmes intervalles, 5 fois) jusqu'à ce que la position précise arrive, et la position précise est rejouée 5 fois. Chaque renvoi est une nouvelle trame chiffrée ; le récepteur ignore les doublons (même identifiant d'alerte, même clé de réponse, même position) et ne vibre qu'à la première réception. Retirer l'alerte ou verrouiller arrête les renvois.
- **Clé du canal dans le binôme.** La clé publique du canal des medics voyage aussi dans les messages « liste » du binôme (un message à part, parce que trois proches aux pseudos longs remplissent déjà le premier), renvoyés dès qu'un proche crée ou apprend la clé. Elle ne remplace jamais une clé déjà connue, et rescanner le code d'un proche déjà dans le binôme la transmet aussi. Le niveau de confiance est celui de l'appairage en face à face. Elle n'ouvre rien : elle permet seulement d'écrire une alerte.
- **Boussole.** Pour un medic, l'écran d'une alerte donne la direction écrite, puis une flèche qui tourne avec le téléphone. Le cap vient du capteur d'orientation d'Android (aucune autorisation, aucune bibliothèque tierce), corrigé de la déclinaison magnétique avec la position du medic. Android envoie la matrice de rotation, le cap est calculé côté Dart (testé). L'« avant » est le haut de l'écran quand le téléphone est à plat (moins de 26 degrés d'inclinaison) et l'arrière du téléphone quand il est debout, en portrait comme en paysage (plus de 60 degrés), avec un mélange progressif entre les deux ; les deux directions sont ramenées à une longueur de 1 avant le mélange. Deux premières versions se sont trompées : un seuil franc entre « à plat » et « debout » (cap faux de 180 degrés dans le second cas), puis une simple somme des deux directions (jusqu'à 45 degrés d'erreur en paysage). L'appli est verrouillée en portrait, pour que le haut de l'écran reste le haut du téléphone. Quand la distance est plus petite que l'incertitude des deux positions, la flèche passe en gris avec la mention « Indicatif » : à quelques mètres, deux GPS donnent un cap souvent juste (leurs erreurs se ressemblent) mais rien ne le garantit. La position du medic est relue toutes les 5 secondes tant que l'écran est ouvert, en mode « précis » : on attend le GPS (jusqu'à 7 secondes) au lieu de prendre la première position venue, parce qu'une position réseau (30 à 100 m d'erreur) ne vaut rien pour guider. Une alerte, elle, part avec la première position reçue, pour ne pas attendre un GPS qui n'accroche pas. Même règle pour la position précise envoyée à un medic. Tant que la position de l'alerte n'est qu'approximative, la flèche mène à la zone (200 m), pas à la personne.
- **Se faire trouver : balise Bluetooth et clignotement.** Le GPS ne guide pas à quelques mètres. Une fois qu'un medic a répondu, la personne peut ouvrir « Aider à me trouver » : son téléphone ajoute alors à son annonce Bluetooth une balise de 5 octets (données constructeur, numéro 0xFFFF, ce qui tient avec l'identifiant d'événement dans les 31 octets d'une annonce). La balise est dérivée de la clé de réponse de l'alerte, que seuls la personne et les medics qui ont reçu l'alerte connaissent : pour un autre, ce sont cinq octets au hasard. Le medic ouvre « Chaud / froid » : son téléphone, qui scanne déjà, relève la force du signal de cette balise. Un enregistrement de 15 minutes entre les deux téléphones (2100 mesures, 3 par seconde) a montré que, à distance fixe, le signal reste plat quelques secondes puis saute de 5 à 7 dB : la façon de tenir le téléphone ou une main devant l'antenne compte autant que la distance, et les trois canaux d'annonce arrivent à des forces différentes. On garde donc le plus fort de chaque seconde et la médiane des cinq dernières, et on compare ce niveau à celui d'il y a 4 secondes, avec un écart d'au moins 4 dB, pour dire « tu te rapproches » ou « tu t'éloignes ». La tendance affichée ne change qu'après trois secondes de constance. Un trait sur la jauge marque le meilleur signal vu depuis l'ouverture de l'écran. À courte distance (au-dessus de -64 dBm, ce que donnent deux téléphones collés), le signal varie trop pour une tendance : l'écran dit de chercher le point où la jauge est la plus haute et propose de demander à la personne de faire clignoter son téléphone. Pas de direction, seulement une tendance. La balise s'arrête avec l'écran, ou au bout de 30 minutes. Le même écran propose de faire clignoter l'écran (blanc et noir, un cycle en 1,2 s) et la lampe arrière, pour se faire repérer à vue ; la lampe ne demande aucune autorisation et s'éteint en quittant l'écran.
- **Reprise après coupure du Bluetooth.** Quand le Bluetooth est éteint pendant l'usage, Android coupe l'annonce, la recherche et les connexions et ne les remet pas en route au rallumage. La radio le signale au moteur (« Bluetooth éteint »), qui libère tout et réessaie toutes les 8 secondes : le maillage repart seul au rallumage. Une minute sans aucun voisin, la radio relance aussi l'annonce et la recherche, au cas où l'une d'elles se serait endormie en silence.
- **Changer d'événement.** Scanner le code d'un autre événement propose de quitter l'actuel (groupes avec leurs messages, binômes, canal des medics) et de rejoindre le nouveau, après avoir dit ce qui sera quitté.

### Limites connues

- **Le QR medic donne la lecture de toutes les alertes** avec leurs positions approximatives. Pas de rotation de la clé du canal : si un QR medic fuite, il faut recréer le canal et redistribuer.
- **Pas d'accusé de réception.** Celui qui signale ne sait pas si l'alerte est arrivée tant qu'aucun medic n'a répondu. Les renvois réduisent le risque de perte sans l'éliminer : un medic hors du maillage pendant plus de 30 minutes ne reçoit rien.
- **Un téléphone dont le Bluetooth est éteint ne voit rien du maillage.** Les renvois ne servent que si le maillage de l'autre revient dans les temps.
- **Rien n'indique aux autres medics qu'un collègue a répondu** : ils doivent se coordonner entre eux.
- **Fuite possible par la mémoire flash.** Comme pour les messages (section 6), l'état de la chaîne de clés est réécrit dans le coffre à chaque message, mais sans rotation de la clé du coffre, d'anciennes versions des fichiers peuvent rester dans la mémoire flash. La confidentialité persistante de la chaîne est donc réelle en mémoire, pas contre quelqu'un qui récupérerait des restes de flash et la clé du coffre.
- **Les alertes de blessé se perdent si le maillage est coupé.** Verrouillage complet ou Bluetooth éteint : le téléphone n'envoie ni ne relaie rien.
- **Le coffre leurre fait aussi fonctionner binômes et alertes** (même code) : un coffre leurre qui émet des signes de vie n'est pas « silencieux » pour un observateur radio.
- **Batterie non mesurée** avec un check-in toutes les 5 minutes.
- **La balise est visible de qui scanne le Bluetooth.** Un observateur voit une annonce de plus (un identifiant d'événement et cinq octets), sans pouvoir la relier à une personne ni lui donner un sens, pendant que la personne garde l'écran « Aider à me trouver » ouvert. Le clignotement et la lampe se voient de loin, par tout le monde : c'est à la personne de décider.
- **« Chaud / froid » est approximatif.** La force du signal Bluetooth varie de plusieurs dB d'une seconde à l'autre et dépend des corps, des murs et des voitures. On annonce une tendance sur quelques secondes, pas une distance. La portée est de 20 à 50 m en terrain dégagé.
- **Pas encore essayé sur téléphone** pour la balise et la lampe à l'écriture de ces lignes.
- **Pas encore essayé sur téléphone** à l'écriture de cette section.

### Tests

- 22 tests de la chaîne de clés (ordre, pertes, doublons, trames forgées, rejeu, usurpation de signature), 15 tests de binôme (appairage, silence, retour, liste de proches, départ, effacement), 21 tests d'alerte (canal, relais par des tiers, réponse, position précise, expiration, vie privée), 11 de géométrie et de marge d'incertitude, 9 des écrans, 5 des renvois (alerte lancée hors de portée, réponse perdue puis rattrapée, position rejouée sans revibrer), 3 de la reprise après coupure du Bluetooth, 3 de la clé du canal dans le binôme, 5 du changement d'événement et de la fin d'événement, 12 de la boussole (dont le cap à plat, debout, en paysage et incliné), 9 des défauts trouvés à la revue, 12 de la balise, du chaud / froid et du clignotement. Au total 305 tests passent.

### Essai sur téléphone, 20 octobre 2026 (HONOR et OnePlus)

Faits depuis le PC, en lisant l'écran des téléphones et en appuyant à distance par adb :

- Bluetooth coupé puis rallumé sur le OnePlus : « Bluetooth éteint » pendant la coupure, puis « actif, 1 voisin » 6 secondes après le rallumage, sans rien toucher.
- Trois alertes de suite (blessure, malaise, gaz) du HONOR vers le OnePlus, chacune avec sa réponse reçue du premier coup ; position précise reçue, boussole démarrée ; vibration longue du OnePlus verrouillé à la réception d'une alerte (relevée dans le journal du vibreur d'Android).
- Ce que l'essai a révélé et qui a été corrigé ensuite : un cap de boussole faux quand on tient le téléphone debout (écart de 180 degrés, voir « Boussole » plus haut), une flèche qui n'a pas de sens quand l'alerte est à quelques mètres (deux GPS qui se contredisent), et la clé du canal des medics qui restait après avoir quitté le dernier binôme.

## 16. Revue du code (20 octobre 2026)

Relecture complète du coffre, de la crypto, du maillage, des services binôme et medic, de la radio, des écrans et du code Android. Ce qui a été corrigé, chacun avec un test :

- **Le coffre se remplissait.** Il a une taille fixe de 256 Kio ; un groupe très bavard l'aurait saturé, après quoi plus aucune écriture n'aurait passé, y compris celle des chaînes de clés du binôme, sans aucun message d'erreur. On garde les 250 messages les plus récents.
- **Chaîne de clés du binôme et appli tuée.** Si Android tue l'appli juste après un envoi, avant la fin de l'écriture du coffre, la chaîne d'envoi recule alors que le proche a déjà avancé : il ne pourrait plus jamais lire nos messages. À chaque réouverture du coffre, on saute maintenant 8 numéros de la chaîne d'envoi (le proche en accepte 64).
- **Position périmée.** La dernière position connue d'Android pouvait dater de plusieurs jours et partir comme position de l'alerte. Au-delà de 5 minutes, elle n'est plus utilisée.
- **Alerte retardée.** L'alerte attendait la position, donc le GPS ou la réponse à la demande d'autorisation. Elle part maintenant au bout de 8 secondes au plus, sans position si besoin.
- **Fausse alerte « plus de nouvelles ».** Quand c'était notre propre Bluetooth qui était coupé, tous les proches étaient déclarés muets. Plus de silence déclaré tant que notre radio est coupée, et un délai de grâce au redémarrage.
- **Pseudos piégés.** Un pseudo pouvait contenir des caractères qui retournent le sens du texte ou des espaces invisibles. Ils sont retirés à la réception (messages, listes de proches, réponses de medics, codes scannés).
- **Fin d'événement manquée.** L'effacement automatique pouvait mettre fin à un événement sans le signaler à la radio ni l'enregistrer. Corrigé.
- **Planton.** Signaler, retirer l'alerte puis signaler à nouveau en moins de 15 secondes levait une exception qui laissait l'écran bloqué sur « Envoi... ».
- **Écrans qui plantaient** si le groupe ou le binôme avait disparu pendant qu'ils étaient ouverts.
- **Panne passagère du Keystore** pendant un déverrouillage derrière l'écran de code : elle détruisait le coffre en mémoire et le maillage. Elle refuse maintenant seulement le code.
- **Journal du téléphone.** La radio y écrivait ses étapes. C'est désactivé dans les builds normaux (`--dart-define=CORTEGE_TRACE=true` pour le réactiver pour un essai).

Défauts connus, non corrigés :

- **L'APK de test est signé avec la clé de débogage.** À remplacer par une vraie clé avant toute diffusion.
- **Pas de limitation des essais de code**, et les paramètres d'Argon2id ne sont pas réglés sur des téléphones d'entrée de gamme (déjà notés en section 6).
- **Chaque message réécrit tout le coffre** (256 Kio chiffrés et écrits). Sans conséquence aux débits d'un groupe, mais coûteux en batterie et en usure de la mémoire flash si le trafic est dense.
- **Liens en double vers un même voisin.** Android change l'adresse Bluetooth d'un téléphone toutes les 15 minutes environ ; l'ancienne connexion reste ouverte un moment, et on la compte comme un voisin de plus (3 voisins observés pour un seul téléphone). Sans identité, on ne peut pas les relier. En foule dense, ces liens fantômes peuvent occuper les 4 connexions sortantes.
- **Arrêt et redémarrage rapprochés de la radio.** Un verrouillage complet suivi aussitôt d'un déverrouillage peut faire se chevaucher l'arrêt de l'ancienne radio et le démarrage de la nouvelle. En pratique, saisir le code prend plus de temps que l'arrêt.
- **Restes dans la mémoire flash** : réglés pour le coffre par le renouvellement du secret matériel (section 6). Restent hors de portée : la copie en clair, le temps d'un import, du fichier de carte dans le dossier privé, et les fichiers d'organisateur reçus avant l'import.

## 17. Infos des organisateurs et carte hors ligne (étape e)

### Décisions du 21 octobre 2026

- **Moteur de carte écrit pour l'appli, en Dart**, plutôt que MapLibre. Raison : MapLibre embarque un client réseau complet (OkHttp) dans l'appli, inutilisé faute de permission mais présent, et son fonctionnement sans réseau sur Android n'était pas vérifié. Le moteur maison ne demande aucune bibliothèque de plus : la lecture du fichier, le décodage des tuiles et le dessin tiennent dans `lib/map/`. En contrepartie, la carte est plus sobre (routes, bâtiments, eau, parcs, quartiers, quelques lieux utiles) et sans rotation.
- **Zone de test : centre de Paris.** Un extrait de 4 km sur 2,8 km, niveaux de zoom 9 à 15, pèse 5,7 Mo.
- **Paquet des organisateurs importé par fichier.** L'organisateur l'envoie par n'importe quel moyen ; l'appli le vérifie.

### Simplification du 21 octobre 2026 (premier retour)

Retour du premier essai : trop compliqué. Il fallait récupérer trois choses (le QR de la clé, le paquet, la carte), les importer une par une, et l'organisateur devait fabriquer la carte avec un programme à part. Solutions regardées :

- **Trois fichiers importés un à un** : abandonné.
- **Un seul fichier, qui s'ouvre avec Cortège d'un appui** depuis la messagerie ou le gestionnaire de fichiers : retenu.
- **Quick Share d'Android** entre téléphones : d'après sa documentation, il marche sans internet (Bluetooth puis Wi-Fi Direct). Rien à coder : le fichier reçu s'ouvre avec Cortège. Pas vers iOS. Non essayé sur les téléphones de test.
- **Lien de téléchargement** hébergé par l'organisateur : possible avant l'événement, rien à coder dans l'appli, mais il faut un hébergement et le téléchargement laisse une trace.
- **QR animés** : les projets spécialisés annoncent 100 Ko/s au mieux, donc trop lent et fragile en plein soleil pour 5 Mo. Possible pour un paquet seul.
- **Relais Bluetooth par le maillage** : bon pour le paquet seul (quelques Ko), pas pour la carte. Reporté.
- **Point d'accès Wi-Fi local** (comme Briar pour partager l'appli) : lourd, et l'appli ouvrirait un serveur local. Écarté.
- **Pour la confiance** : le fichier contient déjà la clé de l'organisateur. Un organisateur inconnu est présenté avec le nom qu'il se donne (il l'écrit lui-même, ça ne prouve rien) et l'empreinte de sa clé en grand ; il faut un appui explicite sur « Faire confiance et importer ». Un avertissement s'affiche si un organisateur déjà accepté porte le même nom avec une autre clé. Le QR reste possible et reste la méthode la plus sûre. Contrepartie assumée : on gagne une étape, mais si la personne ne compare pas l'empreinte, un faux organisateur peut se faire accepter.
- **Pour fabriquer la carte** : l'outil de l'organisateur lit lui-même la carte du monde de Protomaps par morceaux et en extrait la zone, sans le programme `pmtiles`. À proposer plus tard : créer l'événement dans l'appli (formulaire, signature, export), et empaqueter l'outil en programme à double-clic.
- **Parcours et lieux sans carte** : un événement seul (quelques Ko) suffit. Sans fond de carte, la carte montre le parcours, les lieux, la position, un quadrillage et l'échelle.

**Le fichier unique** (`lib/organizer/event_file.dart`) : octets 0 à 3 « CTB1 », octets 4 à 7 la taille du paquet (grand-boutiste), puis le paquet signé (JSON UTF-8), puis la carte PMTiles jusqu'à la fin. Un paquet seul reste un simple texte JSON, et une carte PMTiles seule s'importe encore. Rien n'y est de confiance : la signature du paquet dit qui parle, et l'empreinte de la carte, écrite dans ce paquet signé, dit si la carte jointe est la bonne. La carte n'est jamais chargée en entier : l'empreinte et le chiffrement lisent la partie du fichier qui la contient.

**Ouverture depuis une autre appli** (Android) : l'appli déclare qu'elle ouvre `application/octet-stream` et `application/x-cortege` (ouvrir ou partager). Les messageries envoient un fichier inconnu en `application/octet-stream`, sans extension dans l'adresse : filtrer sur « .cortege » ne le trouverait pas. Cortège apparaît donc dans le choix d'ouverture de n'importe quel fichier inconnu ; il en contrôle le contenu et refuse ce qui n'est pas à lui. Le fichier est copié dans le dossier privé (1 Gio au plus) et attend la saisie du code : l'écran « Événement » s'ouvre une fois le coffre ouvert. Le bouton « Importer un événement » de l'écran « Organisation » reste dans tous les cas.

### Ce qui est construit

- **Fichier de carte : PMTiles version 3.** Lu par petits morceaux, jamais en entier : en-tête de 127 octets, répertoire racine puis répertoires de second niveau (compressés en gzip), numéro de tuile sur la courbe de Hilbert, tuile décompressée. Les lectures d'un même fichier passent l'une après l'autre (un fichier ouvert n'accepte qu'une opération à la fois : trouvé par un test, trois tuiles en parallèle faisaient échouer deux d'entre elles).
- **Tuiles vectorielles (MVT).** Décodage du format protobuf écrit à la main (200 lignes, sans bibliothèque), fait dans un isolate. Les noms de lieux en 50 langues sont écartés au décodage, ce qui divise la mémoire.
- **Dessin.** Chaque tuile est dessinée une fois, en unités de tuile, dans un `Picture` réutilisé à tous les zooms. Largeurs de routes en mètres réels (une avenue de 14 m reste de 14 m à tous les zooms). Aux petits zooms, seules les grandes routes se dessinent. Les textes (quartiers, noms de rues, symboles) se posent à chaque image, à l'écran, sans se recouvrir. Symboles : H hôpital, P pharmacie, E point d'eau, WC toilettes, M métro. Les postes de police ne sont pas affichés. Un fond de tuile voisine est montré, agrandi, en attendant la bonne. Échelle et attribution « © OpenStreetMap » toujours visibles. Déplacement au doigt, zoom en pinçant, double toucher.
- **Organisateurs de confiance.** Un organisateur montre un QR « CORTEGEO1. » : sa clé publique et son nom. Le scanner affiche son nom et l'empreinte de sa clé (8 caractères) et demande confirmation : c'est décider de croire ses paquets. Importer le fichier d'un organisateur inconnu mène à la même confirmation (voir la simplification plus haut). La liste est dans le coffre et suit l'effacement automatique.
- **Paquet signé.** Un petit document JSON : clé de l'organisateur, signature Ed25519, contenu. La signature couvre un préfixe de contexte (« cortege/org/1 ») puis les octets exacts du contenu. Le contenu : nom, dates de publication et d'expiration (30 jours au plus), parcours (1000 points au plus), lieux (150 au plus : eau, toilettes, rendez-vous, dispersion, poste de secours, aide juridique, sortie, information), contacts (30 au plus, numéros seulement), empreinte de la carte annoncée, clé publique du canal des medics (facultative : elle est transmise au maillage à l'import). Tout ce qui sort des limites est refusé même signé, les noms sont nettoyés des caractères qui retournent le texte. Refus avec une raison en français : pas un paquet, signature fausse, organisateur inconnu (avec son empreinte), expiré, daté du futur (plus de 10 minutes), plus ancien que celui qu'on a.
- **Carte annoncée par son empreinte.** Le paquet signé contient l'empreinte BLAKE2b (256 bits) et la taille du fichier de carte. L'appli n'accepte un fichier de carte que s'il a exactement cette empreinte : une carte trafiquée est refusée, et un fichier de la bonne taille mais modifié est signalé comme altéré.
- **Carte chiffrée au repos.** La carte montre la zone d'un événement : elle n'est pas gardée en clair. Le fichier importé est copié dans le dossier privé de l'appli par le sélecteur de fichiers du système (aucune autorisation de stockage), chiffré par morceaux de 64 Kio (XChaCha20-Poly1305, nonce = identifiant du fichier + numéro du morceau, en-tête authentifié), puis la copie en clair est supprimée. La clé est dans le coffre : quand le coffre efface l'événement, le fichier devient illisible même s'il reste sur le disque, et l'appli supprime les fichiers sans enregistrement valable. L'effacement total supprime le dossier. Lecture au hasard sans tout déchiffrer, avec une réserve de morceaux déchiffrés ; un morceau modifié, un fichier tronqué ou la mauvaise clé sont détectés.
- **Position.** Le bouton GPS de la carte demande l'autorisation Android, donne une première position, puis suit le déplacement une fois par seconde environ tant que l'écran est ouvert (le réseau ne sert que si le GPS se tait depuis 10 secondes). Rien n'est gardé.
- **Outil de l'organisateur** (`tool/organizer/`, `lib/organizer/organizer_tool.dart`) : `keygen` (clé, QR en PNG, empreinte), `event` (le fichier unique : lit `evenement.json`, prépare la carte si `"carte"` est demandé, signe, relit ce qu'il vient d'écrire), `extract` (la carte seule), `show` (vérifie un fichier, dit si la carte jointe est conforme), `qr`, `packet` (paquet seul, ancienne méthode), `hash`. `dart run tool/organizer/organizer.dart ...`, ou sous Windows, où le build de libsodium lancé par `dart run` échoue, `flutter test tool/organizer/runner.dart --dart-define=ORG_ARGS="..."`. Le paquet porte le nom que l'organisateur se donne (champ `by`, signé comme le reste).
- **Préparer une carte** (`lib/map/pmtiles_extract.dart`) : l'outil lit la carte du monde de Protomaps (`https://build.protomaps.com/AAAAMMJJ.pmtiles`, la plus récente des 14 derniers jours qui répond, ou `--source` : une adresse ou un fichier local) par requêtes HTTP « Range », ne descend que dans les répertoires qui contiennent la zone, regroupe les lectures voisines, refuse au-delà de 150 Mo (`max_mo`) avant de télécharger les tuiles, écrit un PMTiles version 3 rangé dans l'ordre des tuiles (contenus identiques écrits une fois, suites de tuiles identiques en une ligne, répertoire racine découpé pour tenir avec l'en-tête dans les 16 premiers Kio). La partie réseau (`tool/organizer/http_source.dart`) est hors de `lib/` : l'appli n'en contient aucune ligne, `test/no_network_test.dart` continue de passer. Essai réel le 21 octobre 2026 : le centre de Paris, zooms 9 à 15, 49 tuiles, 5,4 Mo, en 17 secondes ; l'outil officiel `pmtiles verify` accepte le fichier et `pmtiles show` en donne les mêmes caractéristiques que l'extrait fait avec go-pmtiles. Données OpenStreetMap, licence ODbL.
- **Un dossier de cartes par coffre.** Défaut trouvé en y touchant : ouvrir le coffre leurre supprimait la carte du vrai coffre (le nettoyage retire les fichiers sans enregistrement dans le coffre ouvert). Les cartes vivent maintenant dans `maps/coffre0` et `maps/coffre1`, et celles de l'ancienne disposition, à la racine, sont supprimées.

**Exemple de fichier d'événement** (`evenement.json`, écrit à la main par l'organisateur) :

```json
{
  "nom": "Marche du 21 octobre",
  "heures": 48,
  "carte": true,
  "parcours": [[48.8530, 2.3499], [48.8566, 2.3469], [48.8620, 2.3470]],
  "lieux": [
    {"type": "rdv", "nom": "Départ", "lat": 48.8530, "lon": 2.3499, "note": "Rendez-vous à 14 h."},
    {"type": "eau", "nom": "Point d'eau", "lat": 48.8556, "lon": 2.3470},
    {"type": "secours", "nom": "Poste de secours", "lat": 48.8572, "lon": 2.3480}
  ],
  "contacts": [{"nom": "Permanence juridique", "tel": "01 23 45 67 89"}]
}
```

Types de lieux : `eau`, `toilettes`, `rdv`, `dispersion`, `secours`, `juridique`, `sortie`, `info`. `"carte": true` prend la zone du parcours et des lieux, élargie de 1,5 km ; sinon `"carte": {"zone": [ouest, sud, est, nord], "zoom_min": 9, "zoom_max": 15, "max_mo": 150}`. `"cle_medic"` donne la clé publique du canal des medics.

### Essai sur téléphone, 22 octobre 2026 (HONOR et OnePlus)

- Le fichier unique de l'organisateur d'essai (5,2 Mo, carte du centre de Paris jointe, empreinte e2f2-34f4) s'importe sur les deux téléphones : par l'ouverture depuis l'appli Fichiers sur le OnePlus, par « Importer un événement » sur le HONOR. L'écran « Événement » s'affiche avec l'empreinte, l'import prend quelques secondes, la carte s'affiche, et l'événement et la carte se retrouvent dans « Organisation ».
- Sur le OnePlus, Cortège n'apparaît que sous « Autre » dans la liste d'ouverture d'Android : le classement dépend d'Android et de l'habillage du constructeur, l'appli ne peut pas l'imposer. Le chemin sûr est donc le bouton d'import dans l'appli, rendu plus visible ensuite (bouton sur l'écran de la carte quand il n'y a pas encore d'événement, tuile « Organisation » de l'accueil renommée).
- Pas encore essayés : l'ouverture depuis Signal ou WhatsApp, Quick Share, le bouton GPS et les fiches de lieux sur la carte, le comportement à l'effacement automatique.

### Limites connues

- **Un paquet ne prouve que qui l'a écrit**, pas que ce qu'il dit est juste. Il n'y a pas de révocation : si la clé d'un organisateur fuit, il faut le retirer de la liste sur chaque téléphone.
- **Le paquet ne passe pas par le maillage** : fichier seulement pour l'instant.
- **Confiance par comparaison d'empreinte** : plus simple que le QR, mais elle ne vaut que si la personne compare vraiment. L'écran le dit en toutes lettres. Une confirmation de plus (par exemple lire l'empreinte à voix haute) n'est pas ajoutée.
- **L'outil de l'organisateur n'est pas un programme à double-clic** : il demande l'environnement de développement (Flutter). L'empaqueter, ou créer l'événement dans l'appli, est la suite logique si les organisateurs butent là.
- **L'ouverture depuis une messagerie** repose sur ce que l'autre appli envoie à Android : Signal, WhatsApp et le gestionnaire de fichiers n'ont pas tous été essayés.
- **Pas de secret d'événement dans le paquet** : il aurait fait de tout porteur du paquet un relais, et rendu l'événement repérable si le paquet circule largement. À décider si le besoin se confirme.
- **La copie temporaire en clair** du fichier de carte, dans le dossier privé de l'appli, existe le temps de l'import ; comme pour le coffre, des restes peuvent subsister dans la mémoire flash.
- **Carte sobre** : pas de rotation, pas de recherche d'adresse, noms de rues seulement aux zooms élevés, polices du système.
- **Android seulement.**

### Tests

- 10 de la lecture PMTiles (courbe de Hilbert, en-tête, tuiles, fichiers abîmés ou tronqués), 3 du dessin (fond, parcours, lieux, position) sur le fichier d'essai, 27 des organisateurs, des paquets, de la carte chiffrée et de l'effacement.
- Après la simplification : 6 du format du fichier unique, 15 de l'import (organisateur de confiance ou inconnu, nom déjà pris, carte jointe altérée ou non annoncée, carte reçue après coup, fichier sans nouveauté, plus ancien, expiré, signature cassée, carte seule), 9 de l'extraction de carte (sur une source de test de plusieurs centaines de tuiles, avec et sans répertoires de second niveau, et sur 28 000 tuiles pour le découpage du répertoire racine), 11 de l'outil de l'organisateur (dont la recherche de la carte la plus récente, les zones, les refus), 12 des écrans (import en un appui, organisateur inconnu, annulation, fichier ouvert depuis une autre appli après la saisie du code, carte sans fond), 1 des dossiers de cartes par coffre. Les tests de l'extraction comparent un fichier écrit par l'extracteur et un fichier écrit à part (`test/support/pmtiles_builder.dart`), relus par le même lecteur, qui a été vérifié sur de vraies cartes. Le fichier d'essai (`test/fixtures/paris_fixture.pmtiles`, 391 Ko) vient d'OpenStreetMap, © les contributeurs d'OpenStreetMap, ODbL.

## 18. Étapes

- a. Squelette, verrouillage, code de contrainte, effacement automatique (validé sur un téléphone le 18 octobre 2026)
- b. Fiches droits et premiers secours hors ligne (texte de remplacement marqué à faire valider) : validé sur un téléphone le 18 octobre 2026 ; le texte juridique et médical reste à écrire par des personnes qualifiées
- c. Messagerie maillée Android vers Android : validée sur le HONOR et le OnePlus le 18 octobre 2026, avec ses limites (section 14)
- d. Mode binôme et alerte blessé : validé le 21 octobre 2026 sur le HONOR et le OnePlus (binôme, alerte, réponse, position précise, boussole, balise Bluetooth « chaud / froid », clignotement). Limites connues dans les sections 15 et 16.
- e. Infos des organisateurs et carte hors ligne : écrit et testé sur PC, simplifié après un premier retour (un seul fichier, ouverture d'un appui, carte facultative, outil en une commande), validé le 22 octobre 2026 sur le HONOR et le OnePlus (import du fichier unique, carte). Pas encore essayés : l'ouverture depuis Signal ou WhatsApp, Quick Share, le GPS sur la carte, l'effacement automatique de la carte (section 17)
- f. Interopérabilité iOS : reportée. Il faut un Mac (Xcode) et un iPhone pour construire et tester le Bluetooth ; reporté le 22 octobre 2026. Compiler dans le cloud sans iPhone pour l'essayer ne servirait pas à valider quoi que ce soit. À reprendre le jour où ce matériel existe.
- Entre-temps : durcir l'Android, voir la section 6. Fait : limite des essais de code (validée sur téléphone le 22 octobre 2026), renouvellement du secret matériel (23 octobre 2026, à essayer sur téléphone). Mesuré : le déverrouillage prend 160 ms. Reste : vraie clé de signature de l'APK, effacement quand l'appli est fermée, réglage d'Argon2id sur un téléphone d'entrée de gamme, texte juridique et médical à faire écrire par des personnes qualifiées.

Chaque étape attend ta validation avant la suivante.

## 19. Rendre l'appli disponible (24 octobre 2026)

### Options regardées

- **Fichier de l'appli (APK) sur un site ou sur GitHub ou Codeberg** : pas de compte, personne ne peut la retirer ; chacun doit autoriser l'installation hors magasin, pas de mises à jour automatiques.
- **F-Droid** : exige une appli libre (GPL-3.0 convient), une chaîne de fabrication entièrement libre, et reconstruit lui-même l'appli à partir du code source public, ce qui prouve que le fichier correspond au code. La fabrication de libsodium par les hooks du paquet `sodium` reste à faire vérifier avec eux.
- **IzzyOnDroid** : dépôt compatible F-Droid qui reprend les fichiers publiés par le développeur (code public sous licence libre, pas de pisteurs). Limite de 30 Mo par appli, rapportée par un fil de discussion : l'APK universel actuel pèse 53,4 Mo, une version par type de processeur est à tester.
- **Google Play** : plus grand public, mais l'identité du développeur y est liée, l'appli peut être retirée, et un nouveau compte personnel doit d'abord faire un test fermé avec 12 testeurs pendant 14 jours.
- **De téléphone à téléphone** : voir plus bas, fait.
- **iPhone** : impossible pour l'instant (section 18).

### Point d'attention : la vérification des développeurs par Google

Selon Google (developer.android.com/developer-verification), à partir du 30 septembre 2026 au Brésil, en Indonésie, à Singapour et en Thaïlande, puis dans le monde en 2027, Android voudra n'installer que des applis de développeurs enregistrés, même hors Play Store, sur les téléphones certifiés. Des comptes « distribution limitée » (étudiants, enseignants, amateurs) permettent de partager avec 20 appareils au plus sans pièce d'identité ni frais. Un « parcours avancé » (attente de 24 heures, une fois par téléphone) permet d'installer une appli non vérifiée ; l'installation par ADB serait exemptée. Les sources se contredisent sur l'état exact du parcours avancé au 24 octobre 2026 : à revérifier avant de décider. Conséquence : une diffusion large d'un APK par un développeur non enregistré risque de devenir difficile en France à partir de 2027.

### Ordre recommandé

1. Avant tout : une vraie clé de signature (faite le 24 octobre 2026) et les fiches relues (le test de diffusion refuse sinon : pour la première version d'essai, ce choix est assumé, voir plus bas).
2. Petit essai de confiance : le fichier signé, passé de main en main à quelques groupes, avec son empreinte.
3. Code source public, puis F-Droid et IzzyOnDroid.
4. Plus tard, peut-être, Google Play.

### Partager l'appli (fait)

- **Principe** : « Partager l'appli » (accueil) copie le fichier d'installation de l'appli (`applicationInfo.sourceDir`) dans `cache/share/` et ouvre la feuille de partage d'Android (Bluetooth, Quick Share, clé USB...). Ce fichier est celui d'où l'appli a été installée : le coffre, les groupes et les messages n'y sont pas. L'envoi est fait par Android, l'appli ne touche à aucun réseau.
- **Prêt de fichier** : un `FileProvider` non exporté, limité au seul dossier `cache/share/`, donne à l'appli choisie une autorisation de lecture ponctuelle. Rien d'autre du stockage de l'appli n'est exposé.
- **Empreinte** : l'écran montre la taille et les 8 premiers octets de l'empreinte BLAKE2b (libsodium) du fichier, en quatre groupes de quatre signes. L'autre personne voit la même dans son propre « Partager l'appli » une fois l'appli installée : même empreinte, même fichier. Ce n'est pas une preuve d'authenticité (un fichier modifié pourrait afficher n'importe quoi) : l'écran dit de ne recevoir l'appli que d'une personne de confiance, et la vraie vérification sera la comparaison avec une empreinte publiée, une fois la clé de signature réelle en place.
- **Refus** : une installation en plusieurs morceaux (splits) ne se partage pas, son fichier de base ne s'installerait pas chez l'autre personne : l'écran le dit et n'offre pas l'envoi.
- **Nettoyage** : la copie (environ 53 Mo) est supprimée à la prochaine ouverture du coffre et à l'effacement total.
- **Limites** : la personne qui reçoit doit autoriser l'installation depuis la source choisie ; à partir de 2027, la vérification des développeurs de Google pourra demander le parcours avancé ; une appli signée avec la clé de test ne se met pas à jour avec une version signée autrement.
- **Tests** : 10 (empreinte, écran, partage qui ne s'ouvre pas, refus, canal Android simulé, tuile d'accueil).

### Préparation du dépôt public (24 octobre 2026, rien n'est publié)

- Fichiers ajoutés à la racine : `.gitignore` (clés `.cle`, clés de signature, vidéos, zips, sauvegardes, tests jetables `spikes/`, dossiers de construction), `SECURITY.md` (signalement privé par GitHub, pas d'adresse personnelle), `CONTRIBUTING.md` (règles qu'on ne change pas, tests, fiches). Le README annonce l'état réel : version d'essai, code non relu de l'extérieur, fiches non relues, clé de test, mention de l'aide de l'assistant.
- Contrôle des fichiers à envoyer (219) : aucune clé, aucun mot de passe, aucune adresse e-mail, aucun chemin de l'ordinateur ; aucun fichier de plus de 1 Mo.

### Première version d'essai publique (24 octobre 2026, préparée, pas encore publiée)

- **Fiches.** Le responsable du projet a choisi d'inclure les brouillons de fiches, avec leur bandeau « À FAIRE VALIDER », dans la première version publique. Il avait été prévenu que cela contredit la règle de diffusion du projet : le contrôle `CORTEGE_RELEASE_CHECK=1` échoue exprès tant que les fiches ne sont pas relues, et il échoue donc pour cette version. C'est un choix assumé, que les notes de la release disent.
- **Clé de signature.** Clé RSA de 4096 bits créée le 24 octobre 2026, gardée hors du dépôt (le `.gitignore` refuse `key.properties` et `*.jks`). Empreinte SHA-256 de son certificat : `20:95:2E:13:8B:98:D6:55:91:45:BD:EC:92:FA:97:25:3E:AD:83:66:ED:DD:E3:C8:5E:CF:D7:F3:A6:36:F3:11`. Elle signera toutes les mises à jour : si elle est perdue, elle ne peut pas être remplacée, et chaque personne devrait désinstaller l'appli (et perdre son coffre) pour passer à une autre clé. La sauvegarde hors ligne de la clé et de son mot de passe est à la charge du responsable du projet.
- **Construire avec la clé.** `app/android/key.properties` (non versionné) donne le fichier de clé, l'alias et les mots de passe. Sans lui, la construction signe avec la clé de test d'Android et l'avertit.
- **Téléphones d'essai.** Les APK d'essai déjà installés portent la clé de test : Android refuse de les mettre à jour avec la vraie clé. Il faut désinstaller d'abord, et le coffre est perdu.
- **Logo.** L'icône de l'appli était le logo Flutter par défaut. C'est maintenant le logo du projet (`logo/cortege-logo.png` : une maille jaune en forme de C autour d'un point blanc, sur fond noir). Les icônes de toutes les tailles sont tirées de ce fichier, avec une couche « adaptative » sur fond noir pour les Android récents (le logo tient dans la zone sûre, sous un masque rond, arrondi ou carré). Pas d'icône monochrome pour l'instant : les thèmes d'icônes d'Android 13 ne s'y appliquent pas.
- **Version.** 0.1.0-essai, code de version 1. Le code de version doit augmenter à chaque mise à jour publiée.
- **Essai du fichier signé (HONOR, 24 octobre 2026)** : une première version du fichier, installée après désinstallation de la version de test, s'ouvre, et l'écran « Partager l'appli » affiche l'empreinte courte calculée sur l'ordinateur. Le SHA-256 du fichier installé sur le téléphone était celui du fichier de publication. Le nouveau logo a ensuite changé le fichier (nouvelle empreinte courte `4e8a f9b7 6a37 f23d`, recalculée avec le code de l'appli) : mise à jour sur le téléphone à vérifier.
- **Vérifier un fichier téléchargé.** Les notes de la release donnent l'empreinte SHA-256 du fichier, à comparer avec celle que calcule l'ordinateur de la personne, et l'empreinte courte de l'écran « Partager l'appli » une fois l'appli installée.

## 20. Contrôle du code (24 octobre 2026)

Ce contrôle a été fait par l'assistant qui a écrit le code, en relisant les fichiers et en écrivant des tests qui attaquent l'appli. Ce n'est pas un audit indépendant : personne d'extérieur n'a relu ce code. Il faut en faire un avant de promettre quoi que ce soit à des gens qui risquent gros.

### Trois passes

1. **Ce qui sort du téléphone** : recherche de tout appel réseau, de tout lancement de programme, de toute écriture dans les journaux et de toute donnée personnelle dans `lib/`, `android/` et les ressources. Résultat : aucun appel réseau dans l'appli (seul l'outil de l'organisateur, dans `tool/`, parle au réseau), trois affichages de débogage, tous coupés hors mode débogage. La sauvegarde automatique d'Android et le transfert vers un autre téléphone excluent tous les fichiers de l'appli. La notification du service de fond ne dit rien du contenu.
2. **Fichiers hostiles** : tout ce que l'appli lit venant de l'extérieur (fichier d'événement, paquet signé, carte, cartes de tuiles, QR, trames Bluetooth) a été attaqué par des entrées tronquées, mutées, aléatoires ou construites pour exploser (`test/fuzz_parsers_test.dart`, 14 tests, une campagne à grande échelle a aussi été lancée avec `FUZZ_SCALE=12`). L'appli doit refuser proprement, sans planter et sans manger toute la mémoire.
3. **Vie du coffre** : ordre des écritures, verrouillage pendant un renouvellement du secret, changement de code, code de contrainte, effacement, arrêts brutaux simulés (`test/secret_renewal_test.dart`, dont un test de course répété).

### Ce qui a été trouvé et corrigé

- **Cartes qui explosent** : une tuile ou un répertoire compressé en gzip de quelques Ko pouvait se gonfler en plusieurs Go à la lecture. Les tailles sont maintenant plafonnées avant et pendant la décompression (16 Mo compressé, 64 Mo décompressé), et un gzip invalide est refusé comme un fichier de carte abîmé.
- **Tuiles vectorielles piégées** : une étendue de tuile absurde, un indice de clé ou de valeur négatif ou hors tableau, un nombre de lignes énorme ou une lecture au-delà du tampon sont refusés (étendue entre 16 et 65 536, 400 000 objets par couche au plus).
- **Fichier reçu d'une autre appli** : l'appli n'accepte plus que des adresses `content://` (pas de `file://`), copie le fichier dans son espace privé avec un plafond de 300 Mio, et efface la copie ensuite.
- **Changer de code pendant un renouvellement du secret** : les deux opérations pouvaient s'entrecroiser et faire perdre le coffre. Elles sont maintenant en file l'une derrière l'autre, et les vérifications du code se font à l'intérieur de cette file. Un test de course l'avait montré avant la correction.
- **Utiliser une clé après le verrouillage** : un cas faisait planter l'appli (clé libérée, puis utilisée). Chaque usage de clé vérifie d'abord que le coffre est encore ouvert.
- **Code de contrainte et cartes** : ouvrir le faux coffre effaçait la carte du vrai. Chaque coffre a maintenant son propre dossier de cartes.
- **Fuite de fichier ouvert** : une carte refusée laissait son fichier ouvert. Il est refermé.
- **Outil de l'organisateur** : une réponse de serveur plus grosse que demandée est refusée au lieu de remplir la mémoire.
- **Clé des medics fixée par un événement** : l'écran d'import le dit maintenant en toutes lettres avant la confirmation, car cette clé reçoit les alertes de blessé, position arrondie comprise.

### Ce qui reste, et que le contrôle n'a pas réglé

- Le code de déverrouillage passe par une chaîne de caractères de Dart avant d'être transformé en clé : elle reste en mémoire jusqu'au passage du ramasse-miettes. Quelqu'un qui lit la mémoire d'un téléphone déverrouillé peut la retrouver.
- Deux organisateurs qui s'écrivent avec des lettres qui se ressemblent (alphabet latin et cyrillique) ne sont pas distingués par le nom. Seule l'empreinte compte, c'est pourquoi l'écran la montre en grand.
- Le fichier `.cle` de l'organisateur contient sa clé secrète sans mot de passe. Qui le copie signe à sa place.
- Argon2id a été mesuré à 160 ms sur les deux téléphones d'essai, mais n'a pas été réglé pour un téléphone d'entrée de gamme.
- Au moment du contrôle, l'APK était signé avec la clé de test d'Android. La première version publique est signée avec la clé du projet (voir plus haut).
- Si l'appli reste fermée plus longtemps que la durée d'effacement, rien n'est effacé avant la prochaine ouverture : il n'y a pas de balayage en arrière-plan (section 6).
- Aucun test n'a été fait contre un vrai attaquant disposant du téléphone, ni contre un autre appareil Bluetooth malveillant en conditions réelles.

### Tests après contrôle

464 tests réussis et 2 ignorés (le contrôle de diffusion des fiches, qui échoue exprès tant qu'elles ne sont pas relues, et un test de dessin de carte qui demande un fichier de carte précis), analyse statique sans avertissement.

### Essai sur téléphone, 24 octobre 2026 (HONOR et OnePlus)

La version corrigée (APK de 53,4 Mo, clé de test) a été installée sur les deux téléphones, par-dessus l'ancienne.

- **Renouvellement du secret (HONOR)** : après avoir créé puis quitté un groupe, les Réglages affichent « Dernier renouvellement : à l'instant. » Le retrait d'un organisateur n'a pas pu être essayé : il n'y en avait plus sur ce téléphone.
- **Fiches** : le bandeau jaune, la phrase « Brouillon écrit par un assistant… » et la liste des sources s'affichent. Lacrymogènes montre bien 3 « À RÉDIGER », et cinq autres fiches en montrent un chacun (8 au total, comme prévu).
- **Partager l'appli** : l'essai est concluant.
- **Réouverture du coffre (HONOR)** : après le renouvellement, appli arrêtée de force puis rouverte, le code ouvre le coffre (essai concluant). L'écran « Organisation » s'ouvre aussi.
- **Pas encore vérifié sur téléphone** : le retrait d'un organisateur suivi d'un renouvellement, l'ouverture du fichier depuis Signal ou WhatsApp.
