# Relecture des fiches Droits et Secours

Les neuf fiches de `app/assets/content/` ont été rédigées le 24 octobre 2026 par l'assistant de développement, à partir de sources officielles lues ce jour-là (service-public.gouv.fr, Légifrance, ministère de la Justice, Croix-Rouge, Assurance maladie, INRS, Manuel MSD). Chaque fiche termine par la liste de ses sources.

**Aucune personne qualifiée n'a relu ces textes.** L'assistant n'est ni juriste ni secouriste. Une erreur sur un droit ou sur un geste de secours peut faire du mal.

## Où elles en sont dans l'appli

Le 24 octobre 2026, le responsable du projet a décidé en connaissance de cause de les afficher avant relecture. Chaque fiche porte l'en-tête `redaction: brouillon_source`. L'écran montre alors, en jaune plein, « À FAIRE VALIDER PAR UN JURISTE » (ou « PAR DES SECOURISTES »), puis la phrase « Brouillon écrit par un assistant d'après des sources officielles. Personne ne l'a relu. Les sources sont en bas de la fiche. »

Les tests (`app/test/content_catalog_test.dart`) continuent de refuser du texte dans une fiche non relue, sauf pour un brouillon sourcé qui cite ses sources (adresses `https://`), dit qu'aucune relecture humaine n'a eu lieu, n'utilise pas de tiret long et tutoie. Le test de diffusion (`CORTEGE_RELEASE_CHECK=1`) échoue tant qu'une fiche n'est pas relue : ces brouillons ne peuvent donc pas partir dans une version diffusée.

## Qui doit relire

- Droits (4 fiches : contrôle d'identité, fouille, garde à vue, contacts utiles) : un juriste ou un avocat.
- Secours (5 fiches : numéros d'urgence, blessure, malaise, chaleur, lacrymogènes) : des secouristes ou un médecin.

Chaque fiche contient des lignes `!` « À faire vérifier » qui marquent ce dont l'assistant doute. Les lignes `?` sont des questions restées sans réponse faute de source : 8 sur les 61 d'origine. Elles s'affichent « À RÉDIGER ».

## Ce qui reste à vérifier, en plus des lignes `!`

Droits :
- Les articles du code de procédure pénale cités (78-1 à 78-5, 62-2, 63 à 64-1, 706-88) seront abrogés et remplacés par un nouveau code le 1er janvier 2029 (ordonnance n° 2025-1091 du 19 novembre 2025). À revoir à ce moment.
- La déclaration des droits lue pour la garde à vue est celle du trafic de stupéfiants. Pour une garde à vue ordinaire, le délai de 3 heures pour prévenir un proche et la durée du report de l'avocat sont à confirmer.
- Le droit de filmer et la diffusion des images viennent d'Amnesty France, pas d'un texte officiel.
- Aucun numéro de téléphone du Défenseur des droits n'a pu être vérifié.
- Le téléphone : la jurisprudence de la Cour de cassation depuis novembre 2022.

Secours :
- Le garrot vient d'un compte rendu du guide « Les gestes qui sauvent » (ministère de l'Intérieur, 2024) : le site du ministère était inaccessible à l'outil, le guide n'a pas été lu.
- Lacrymogènes : aucune consigne officielle propre à la manifestation n'a été trouvée. Les sources sont l'INRS (monde du travail, fiche CS de 2014), le Manuel MSD, et la presse pour deux points.
- Les pages de la Croix-Rouge n'indiquent pas de date de mise à jour, et donnent deux rythmes de compressions (100 et 120 par minute) : la fiche dit « environ 2 par seconde ».
- Les seuils de température du coup de chaleur varient selon les sources.

## Comment une fiche est validée

1. La personne qui relit corrige le fichier de `app/assets/content/droits/` ou `secours/`.
2. Dans l'en-tête, remplacer `statut: a_valider` par `statut: valide`, ajouter une ligne `relu_par: Nom, date`, et retirer `redaction: brouillon_source` (le programme refuse de lire une fiche validée qui garde cette mention).
3. Lancer `flutter test`.
4. Avant toute diffusion, `CORTEGE_RELEASE_CHECK=1 flutter test test/content_catalog_test.dart` doit passer : les neuf fiches doivent être relues.

Une fiche partiellement validée ne doit pas passer : tout ou rien, fiche par fiche.

## Revenir en arrière

Pour ne plus montrer ces textes dans l'appli, remplacer chaque fiche par un squelette : l'en-tête, les titres de section et les lignes `?`, sans aucun texte rédigé. Retirer seulement la ligne `redaction: brouillon_source` ne suffit pas : le test refuse alors le texte et signale la fiche.
