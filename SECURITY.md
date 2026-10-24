# Signaler une faille

Cortège est faite pour des gens qui peuvent être surveillés ou fouillés. Une faille peut donc faire du mal à de vraies personnes. Merci de nous la signaler avant de la rendre publique.

## Comment

Utilise le signalement privé de GitHub : onglet **Security**, puis **Report a vulnerability**. Rien de ce que tu écris là n'est visible des autres. Ne publie pas la faille dans une « issue » ouverte.

Si tu ne peux pas passer par GitHub, ouvre une issue publique qui dit seulement « j'ai trouvé une faille, comment vous la transmettre ? », sans aucun détail.

Dis-nous, si tu peux :

- ce qui est touché (le coffre, le code de contrainte, la messagerie, l'alerte blessé, la carte, les fichiers des organisateurs, l'outil de l'organisateur) ;
- la version de l'appli et le téléphone ;
- les étapes pour la reproduire, ou un fichier qui la déclenche ;
- ce qu'un attaquant y gagne.

## Ce que nous promettons

Rien de précis sur les délais : le projet est maintenu par peu de personnes. Nous lisons chaque signalement, nous répondons, et nous corrigeons les failles qui touchent aux promesses de l'appli avant toute autre chose. Si tu le demandes, ton nom n'est pas cité.

## Ce qui compte comme une faille

Tout ce qui casse une des promesses du [README](README.md) :

- l'appli envoie quelque chose sur un réseau ;
- une trace de position, de message ou de contact survit à l'effacement ;
- le code de contrainte se distingue du vrai code ;
- un fichier reçu (événement, carte, QR, trame Bluetooth) fait planter l'appli, lit un fichier qu'il ne devrait pas lire ou fait croire à une fausse identité d'organisateur ;
- le code ou le coffre peuvent être devinés plus vite que prévu.

## Ce qui est déjà connu

La section « Limites » du README et la section 20 de [ARCHITECTURE.md](ARCHITECTURE.md) listent ce que nous savons ne pas avoir réglé. Le contrôle fait jusqu'ici est un contrôle de l'équipe, pas un audit indépendant. Un audit extérieur est le bienvenu.
