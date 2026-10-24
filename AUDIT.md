# Auditer Cortège

Ce document dit où regarder. Il ne contient rien de plus que les autres documents du dépôt : il les rassemble pour qui veut relire le code.

## Ce qu'il faudrait casser

Les promesses de l'appli sont dans la section « Ce que l'appli garantit, et ce qu'elle ne garantit pas » du [README](README.md). Le modèle de menace est dans la section 10 d'[ARCHITECTURE.md](ARCHITECTURE.md). Une faille, c'est tout ce qui casse une de ces promesses.

## Où lire, zone par zone

1. **Coffre, code, effacement et renouvellement du secret** : `app/lib/vault/`, `app/lib/crypto/vault_crypto.dart`, `app/android/app/src/main/kotlin/org/cortege/app/HardwareSecret.kt`. Explications : section 6 d'ARCHITECTURE.md. Tests : `vault_store_test.dart`, `secret_renewal_test.dart`, `attempt_limiter_test.dart`.
2. **Messagerie par Bluetooth, binôme, alerte blessé** : `app/lib/mesh/`. Explications : sections 3, 4, 8, 14 et 15. Tests : `mesh_relay_test.dart`, `medic_flow_test.dart`.
3. **Tout ce que l'appli lit venant de l'extérieur** (fichier d'événement, paquet signé, carte, QR) : `app/lib/organizer/`, `app/lib/map/pmtiles.dart`, `app/lib/map/mvt.dart`, et la réception des fichiers dans `MainActivity.kt` et le manifeste Android. Explications : sections 17 et 20. Tests : `event_file_test.dart`, `organizer_test.dart`, `pmtiles_test.dart`, `fuzz_parsers_test.dart`.
4. **Aucun accès au réseau** : le manifeste Android et `app/test/no_network_test.dart`. L'outil de l'organisateur, dans `app/tool/organizer/`, est le seul code qui parle au réseau, sur l'ordinateur de l'organisateur.
5. **Partage de l'appli** : `app/lib/share/app_sharer.dart` et le prêt de fichier dans `MainActivity.kt`. Explications : section 19.

## Construire et tester

Les étapes sont dans la section « Construire » du README. Pour lancer les tests :

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

Les tests d'attaque sur les fichiers reçus acceptent un multiplicateur : `FUZZ_SCALE=10 flutter test test/fuzz_parsers_test.dart` (sous PowerShell : `$env:FUZZ_SCALE = '10'` avant la commande).

## Ce qui est déjà connu

La section 20 d'ARCHITECTURE.md liste ce que le contrôle fait par l'équipe a trouvé, ce qui a été corrigé, et ce qui reste. Elle dit aussi ce qui n'a pas été testé. Si tu penses qu'une de ces limites est plus grave que ce qui est écrit, dis-le.

## Hors du périmètre

- Les fiches Droits et Secours sont des textes, pas du code : leur relecture se décrit dans [RELECTURE-DES-FICHES.md](RELECTURE-DES-FICHES.md).
- iOS n'existe pas.

## Signaler quelque chose

Une faille se signale en privé, comme décrit dans [SECURITY.md](SECURITY.md). Ne la publie pas dans une « issue » avant qu'elle soit corrigée.
