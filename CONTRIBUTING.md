# Contribuer

Merci de vouloir aider. Cortège est une appli de sécurité pour les manifestations : ce qui compte, c'est que ses promesses tiennent. Lis d'abord [ARCHITECTURE.md](ARCHITECTURE.md), qui explique les choix et les limites.

## Ce qu'on ne change pas

Ces règles sont les raisons d'être de l'appli. Une modification qui en casse une sera refusée, même si elle est utile par ailleurs.

- Aucun compte, aucun numéro de téléphone, aucun e-mail.
- Aucun serveur, aucune requête réseau dans l'appli. Pas de permission `INTERNET`, pas de bibliothèque de statistiques, de plantages ou de publicité. Le test `test/no_network_test.dart` le vérifie. L'outil de l'organisateur (`app/tool/`) est le seul code qui parle au réseau, sur l'ordinateur de l'organisateur.
- Aucune position gardée sur le téléphone. Aucun historique des déplacements.
- Tout ce qui est gardé s'efface tout seul (24 heures par défaut) et le code de contrainte ouvre un coffre vide crédible.
- La cryptographie vient de libsodium et de rien d'autre. Pas de primitive écrite à la main.
- Les identifiants Bluetooth changent régulièrement. Rien de fixe ne désigne un téléphone.
- Aucune fonction qui signale la position de la police.
- Aucune fonction d'intelligence artificielle dans l'appli.
- Pas de texte juridique ou médical inventé : une fiche cite ses sources, ou elle reste une liste de questions. Voir [RELECTURE-DES-FICHES.md](RELECTURE-DES-FICHES.md).

## Écrire

- Les textes de l'appli sont en français simple, en tutoyant, sans tiret long ni emoji. L'écran est sobre et sombre, lisible en pleine lumière.
- Les commentaires expliquent pourquoi, pas ce que fait la ligne.
- Une nouvelle fonction vient avec ses tests, y compris les cas où le fichier reçu est faux ou hostile.

## Tester

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

Sous Windows, voir la section « Lancer les tests sous Windows » du [README](README.md). `flutter analyze` et `flutter test` doivent passer avant toute demande de fusion. Les contrôles qui échouent exprès tant que les fiches ne sont pas relues (`CORTEGE_RELEASE_CHECK=1`) ne font pas partie de ce passage.

## Fiches droits et secours

Seule une personne qualifiée (juriste, avocat, secouriste, médecin) peut faire passer une fiche à `statut: valide`. Si tu l'es, c'est l'aide la plus précieuse que tu puisses apporter : suis [RELECTURE-DES-FICHES.md](RELECTURE-DES-FICHES.md).

## Failles

Ne les signale pas dans une issue publique : voir [SECURITY.md](SECURITY.md).
