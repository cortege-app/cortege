# Mode d'emploi de Cortège

Cortège est une version d'essai. Elle peut avoir des défauts, et personne d'extérieur n'a relu son code. Avant de t'y fier, essaie-la avec des proches, chez toi, avec au moins deux téléphones. Ce qu'elle ne fait pas est dit en bas de cette page : lis-le.

## Les trois choses à retenir

1. **Ton code ne se retrouve pas.** Si tu l'oublies, tu perds tout.
2. **Prépare tout avant de partir.** Les groupes, le binôme et l'événement se mettent en place chez toi, en face de tes proches, pas dans la rue.
3. **Si on te contrôle,** tu as trois moyens, décrits plus bas : l'écran de code, le code de contrainte, « Tout effacer ».

## Avant de partir (chez toi)

### 1. Installer l'appli

L'appli ne se trouve pas dans un magasin. Deux façons de l'avoir :
- **Télécharge-la** sur **cortege-app.github.io**, et seulement là (ou depuis la page des versions du projet, dont le lien est en haut du [README](README.md)). Compare l'empreinte du fichier avec celle de la page.
- **Ou reçois-la d'une personne en qui tu as confiance** : elle ouvre « Partager l'appli » sur son téléphone et te l'envoie (Bluetooth, Quick Share, clé USB).

Android te demande d'autoriser l'installation depuis cette source : accepte. Ensuite, comparez la ligne « Empreinte » de l'écran « Partager l'appli » sur vos deux téléphones : elle doit être identique.

### 2. Choisir ton code

1. Ouvre Cortège. Appuie sur **Choisir mon code**.
2. Tape un code de 6 à 12 chiffres. L'appli refuse les codes trop faciles, comme 123456 ou 111111.
3. Tape-le une deuxième fois.
4. L'appli propose un **code de contrainte** : c'est un second code, différent du premier. Si on te force à ouvrir l'appli, ce code ouvre une version vide, sans tes groupes ni tes messages. Choisis-en un que tu peux taper sans réfléchir, ou appuie sur « Plus tard, dans les réglages ».
5. Attends quelques secondes : l'appli crée ton coffre.

Choisis un code que tu retiens sans l'écrire. Personne, pas même l'équipe du projet, ne peut le retrouver.

### 3. Les autorisations

Android te les demande au moment où elles servent. Accepte :
- **Bluetooth** : c'est avec lui que les téléphones se parlent.
- **Notifications** : sans elles, l'appli tourne quand même, mais Android cache sa notification « Service actif ».
- **Caméra** : seulement pour scanner un QR.
- **Position** : demandée uniquement quand tu envoies une alerte blessé, que tu affiches ta position sur la carte, ou que tu cherches la direction d'un blessé (medic). L'appli ne garde jamais ta position.

### 4. Les réglages à choisir

Accueil, puis **Réglages**.
- **Effacement automatique** : de 1 h à 72 h, 24 h au départ. Passé ce délai, les messages et les données de l'événement disparaissent.
- **Écran de code** : le délai, hors de l'appli, après lequel le code est redemandé (30 secondes au départ, jusqu'à 15 minutes).
- **Maillage derrière l'écran de code** : combien de temps l'appli continue de recevoir et relayer des messages dans ta poche, avec l'écran de code affiché (1 heure au départ). Plus c'est long, plus tu es joignable, mais plus la clé du coffre reste en mémoire. « Aucun » ferme tout dès l'écran de code.
- **Binôme** : à quel rythme ton téléphone envoie un signe de vie (2, 5, 10 ou 15 minutes).

### 5. Ton pseudo

Messages, puis **Changer mon pseudo** : 1 à 24 lettres. Ce nom est visible des membres de tes groupes. Il n'est pas vérifié : deux personnes peuvent avoir le même, c'est pourquoi un petit code de 6 signes s'affiche à côté. N'utilise pas ton vrai nom si tu ne veux pas qu'on le lise.

### 6. Rejoindre un groupe de messagerie

Un groupe se crée et se rejoint en face à face, avec un QR.
1. Une personne ouvre Messages, appuie sur **Créer un groupe**, donne un nom, puis **Créer**.
2. Elle fait scanner le QR qui s'affiche (l'écran est au maximum de luminosité pour ça).
3. Les autres ouvrent Messages, appuient sur **Rejoindre avec un QR** et scannent.

Si le scan ne marche pas : rapproche-toi, monte la luminosité, ou utilise « Copier l'invitation en texte » puis « Coller un code copié ». Le QR contient la clé du groupe : **ne le photographie pas, ne le publie pas**. Quiconque l'a peut lire et écrire dans le groupe. Un téléphone n'est que dans un seul événement à la fois : le QR d'un autre événement est refusé tant que tu as des groupes.

### 7. Choisir un binôme

Un binôme (jusqu'à 4 personnes) te prévient si un proche ne donne plus signe de vie.
1. Une personne ouvre **Binôme**, puis **Créer un binôme**, puis **Montrer mon code**.
2. L'autre appuie sur **Rejoindre le binôme d'un proche** et scanne ce code.
3. Elle montre ensuite le sien : la première personne appuie sur **Scanner un proche** et le scanne.

Ensuite, un signe de vie part tout seul au rythme choisi tant que le maillage tourne. **Je vais bien** en envoie un tout de suite. Si un proche se tait pendant deux intervalles, une bannière apparaît : « Plus de nouvelles de... ». Elle veut dire qu'on n'entend plus rien de lui (téléphone éteint, Bluetooth coupé, trop loin). L'appli ne sait pas où il est.

### 8. Importer l'événement de l'organisateur

Si un organisateur prépare l'événement, il t'envoie un fichier `.cortege` (messagerie, mail, clé USB) : parcours, lieux utiles, contacts, et parfois une carte.
1. Ouvre le fichier avec Cortège, ou ouvre Organisation, puis **Importer un événement (fichier)**.
2. Si c'est un organisateur que tu ne connais pas encore, l'appli affiche l'**empreinte** de sa clé en grand. Compare-la avec celle que l'organisateur t'a donnée de vive voix ou sur l'affiche. Si elle est différente, **n'importe pas**.
3. Appuie sur **Faire confiance et importer**.

Si l'événement fixe aussi la clé des medics, l'appli le dit : tes alertes de blessé, avec ta position, seront chiffrées pour cette clé. Ne l'importe que si tu fais confiance à son organisateur.

### 9. Un essai à blanc

Avec un proche, chacun un téléphone : envoyez-vous des messages, éloignez-vous, vérifiez la ligne **Maillage** de l'accueil. Elle dit « actif, 1 voisin » quand l'autre téléphone est trouvé. Prends aussi une batterie externe : le Bluetooth reste en recherche continue, et l'usage de la batterie n'a pas encore été mesuré.

## Pendant l'événement

### Messages

Messages, puis ton groupe : écris (des messages courts, environ 300 signes) et appuie sur **Envoyer**. Les messages passent de téléphone en téléphone, par Bluetooth, sans réseau.

À savoir :
- Un message n'est ni mis en attente ni confirmé. Si personne n'est à portée, il est perdu. Un téléphone qui arrive ensuite ne reçoit pas ce qu'il a manqué.
- Ça ne marche que si des téléphones de l'événement sont assez proches les uns des autres pour se relayer.
- Ce que dit la ligne **Maillage** : « actif, 2 voisins » (ça marche), « actif, aucun voisin » (personne à portée), « démarrage... » (patiente), « Bluetooth éteint » (rallume-le : l'appli repart toute seule en quelques secondes), « arrêté » (tout est verrouillé : tape ton code).

### Quand ton téléphone est dans ta poche

Quand tu quittes l'appli, l'écran de code s'affiche après le délai que tu as choisi. Derrière lui, l'appli reçoit et relaie encore, pendant le délai « Maillage derrière l'écran de code ». Au bout, tout se verrouille et le maillage s'arrête : retape ton code pour recommencer à recevoir.

### Signaler un blessé

1. Accueil, puis **Signaler un blessé**.
2. Choisis le type : **Blessure**, **Malaise** ou **Gaz**. Garde le doigt appuyé un instant sur le bouton, jusqu'à ce qu'il se valide.
3. Les medics reçoivent ta position arrondie à environ 200 m, sans ton nom. L'alerte passe de téléphone en téléphone.
4. Quand un medic répond, l'écran affiche « *pseudo* arrive ». Tu peux alors **envoyer ta position précise** à ce medic seulement, ou appuyer sur **Aider à me trouver** : ton téléphone émet un signal Bluetooth que seul ce medic reconnaît, et il peut faire clignoter l'écran et la lampe (ça se voit de loin, par tout le monde).
5. **Retirer cette alerte** la retire de ton téléphone, mais ne la rappelle pas chez les medics qui l'ont déjà reçue.

Une alerte n'est pas confirmée tant qu'aucun medic n'a répondu. S'il n'y a aucun medic à portée du maillage, elle n'arrive pas. **Si c'est grave, appelle le 15 ou le 112.** Les alertes disparaissent d'elles-mêmes au bout de 2 heures au plus.

### Si tu es medic

1. Accueil, puis **Rôle medic**. Si personne n'a encore créé le canal des medics, appuie sur **Créer le canal des medics** (tu deviens le premier medic). Sinon, appuie sur **Rejoindre le canal d'un medic** et scanne le code d'un medic que tu connais, en face à face.
2. Vérifie que la **Réception des alertes** est activée.
3. Quand un blessé est signalé, une bannière apparaît à l'accueil. Ouvre l'alerte : tu vois sa position approximative et la direction depuis ta position.
4. Appuie sur **J'arrive** : le blessé voit ton pseudo. Rien ne prévient les autres medics que tu y vas : préviens-les toi-même.
5. Une fois sur place, **Chaud / froid** donne une tendance à partir du signal Bluetooth du blessé, s'il a appuyé sur « Aider à me trouver ». La boussole est faussée près du métal, d'un haut-parleur ou d'une voiture.

Le code des medics permet de lire **toutes** les alertes de l'événement. Ne le montre qu'à des medics que tu connais.

### La carte

Accueil, puis **Carte** : le parcours et les lieux utiles de l'événement importé (eau, toilettes, rendez-vous, dispersion, secours, sorties). Si l'organisateur n'a pas joint de carte, ils s'affichent sur un fond vide, avec un quadrillage. Les boutons + et - zooment. Le bouton de position affiche ta position, ce qui demande l'autorisation de localisation. Rien n'est téléchargé : tout est déjà sur ton téléphone.

### Droits et Secours

Accueil, puis **Droits** ou **Secours** : des fiches que tu lis sans réseau. **Ces fiches sont des brouillons, écrits par un assistant d'après des sources officielles, que personne n'a relus.** Elles peuvent contenir des erreurs. Chaque fiche dit ses sources en bas. Pour un doute sur un droit, demande à un avocat ou à une permanence juridique. Pour un doute sur un geste de secours, appelle le 15 ou le 112.

## Si on te contrôle ou si on te prend ton téléphone

Trois moyens, du plus léger au plus fort.
1. **Écran de code maintenant** (Réglages) : ferme l'affichage, mais les clés restent en mémoire pendant le délai « Maillage derrière l'écran de code ». Quelqu'un qui sait lire la mémoire d'un téléphone allumé pourrait les récupérer.
2. **Tout verrouiller et arrêter le maillage** (Réglages) : détruit les clés en mémoire et arrête les messages. Il faut ton code pour tout rouvrir.
3. **Tout effacer** (Réglages) : garde le doigt appuyé 3 secondes. Détruit le coffre, les codes et toutes les données, sans retour possible.

Et le **code de contrainte** : si on te force à ouvrir l'appli, tape-le à la place de ton code. L'appli s'ouvre sur une version vide. Ça te sort d'un contrôle rapide. Ça ne trompe pas quelqu'un qui analyse ton téléphone en détail.

Les captures d'écran sont bloquées dans l'appli.

## Après l'événement

- Les messages et les données s'effacent tout seuls, au bout du délai choisi. **Si tu ne rouvres pas l'appli pendant plus longtemps que ce délai, rien n'est effacé avant ta prochaine ouverture** : ouvre-la, ou utilise « Tout effacer ».
- **Quitter un groupe** : Messages, ton groupe, puis **Quitter le groupe**. Les autres membres gardent leurs copies de tes anciens messages jusqu'à la fin de leur propre délai : on ne peut rien effacer à distance.
- **Quitter le binôme** ou **Quitter le rôle de medic** : dans leurs écrans.
- Dans Organisation, **Ne plus faire confiance** retire un organisateur et son événement.

## Si ça ne marche pas

- **Code incorrect** : après 5 codes faux de suite, l'appli t'impose une attente qui grandit (30 secondes, puis jusqu'à 1 heure). Le bon code, ou le code de contrainte, remet le compte à zéro.
- **Code oublié** : sur l'écran de code, appuie sur **Code oublié ?**, sous le clavier. Personne ne peut retrouver ton code. La seule issue est de tout effacer : garde le doigt appuyé 3 secondes sur « Tout effacer ». Tu perds tout ce que l'appli contenait, puis tu choisis un nouveau code. Ça marche aussi pendant l'attente après trop de codes faux.
- **« Position introuvable »** : active la localisation de ton téléphone et réessaie dehors.
- **Le QR ne se scanne pas** : voir plus haut, étape 6.
- **Plus aucun voisin** : rapproche-toi d'un autre téléphone de l'événement, vérifie que le Bluetooth est allumé des deux côtés.
- **Un fichier d'événement est refusé** : l'appli dit pourquoi (expiré, signature fausse, date dans le futur, carte qui ne correspond pas). Si la signature est fausse, **n'utilise pas** ce fichier.

## Ce que l'appli ne fait pas

- Elle ne résiste pas à une analyse poussée du téléphone par des spécialistes.
- Elle ne te rend pas invisible : un observateur peut voir que des téléphones émettent en Bluetooth, et estimer qu'un téléphone est proche. Il ne lit pas les messages.
- Elle ne garde pas les messages et ne confirme pas leur arrivée.
- Elle ne remplace ni le 15, ni le 112, ni un avocat.
- Elle n'existe pas sur iPhone.

La liste complète des limites est dans le [README](README.md).

## Pour les organisateurs

Préparer le fichier d'événement se fait sur ordinateur avec l'outil du projet : voir la section « Carte et paquet des organisateurs » du [README](README.md).
