# agenteiamail

[English](../README.md) · [Español (MX)](README.es-MX.md) · [Español (ES)](README.es-ES.md) · **Français** · [Português (BR)](README.pt-BR.md)

> Traduit de [`README.md`](../README.md) au commit `9682aee`. En cas de divergence
> avec l'original anglais, **c'est l'anglais qui fait foi** — et signalez-le nous,
> car cela veut dire que cette traduction a pris du retard.

Notification immédiate des courriels pour un agent IA. Il apprend l'arrivée d'un
message en une seconde environ, sans interroger la boîte en boucle, et peut lire
et envoyer dans les limites d'une liste de destinataires autorisés.

Construit autour de [Himalaya](https://github.com/pimalaya/himalaya) pour un
compte IMAP/SMTP ordinaire, sous Ubuntu 24.04 avec l'environnement OpenClaw.

---

## Mise en place sur votre agent

Trois étapes. La première est la vôtre seule, la deuxième tient en un
copier-coller, la troisième prend deux minutes pour vérifier que cela fonctionne
vraiment.

### Étape 1 — Donnez-lui une boîte aux lettres

L'agent a besoin de son propre compte de messagerie, et des paramètres de
connexion de ce compte écrits dans `~/.openclaw/workspace/.env`.

**[MAILBOX_SETUP.fr-FR.md](MAILBOX_SETUP.fr-FR.md) vous guide** : quel compte utiliser, où
trouver le nom du serveur (la seule partie qui échoue systématiquement), le
fichier lui-même, et une vérification qui attrape les erreurs courantes avant que
vous n'alliez plus loin.

Faites-le vous-même plutôt que de le demander à l'agent. Il faut un mot de passe,
et un mot de passe ne doit pas transiter par une conversation.

### Étape 2 — Orientez l'agent vers ce dépôt

Collez ceci à votre agent :

```text
Votre compte de messagerie est déjà configuré dans ~/.openclaw/workspace/.env

Installez ce dépôt pour pouvoir l'utiliser :
https://github.com/julianflores/agenteiamail

Suivez AGENTS.md. Demandez-moi tout ce dont vous avez besoin — mais ne me
demandez jamais de coller le mot de passe dans cette conversation.
```

Tout le reste dont l'agent a besoin se trouve dans le dépôt : le texte n'a donc
qu'à l'y renvoyer. La seule règle restée dans le texte y figure parce qu'elle
régit **votre** comportement et non celui de l'agent : un mot de passe collé dans
une conversation y reste définitivement, et aucune précaution ultérieure ne
l'efface.

Attendez-vous à des questions avant qu'il ne commence. Si l'étape 1 s'est bien
passée, elles devraient être rares — et s'il demande le mot de passe, refusez.
Cela ne fait partie d'aucune de ces instructions.

### Étape 3 — Testez vous-même

L'agent exécute sa propre liste de vérification et vous dira qu'elle est passée.
Deux minutes de vos propres tests valent davantage, car vous vérifiez ce qui vous
importe réellement : est-ce qu'il remarque, et est-ce qu'il reste dans ses
limites.

**Test 1 — envoyez-lui un courriel, avec un accent dans l'objet.**

Depuis votre propre adresse, avec un objet du genre `Test — é, à, ç, ça va ?`
Demandez ensuite à l'agent ce qui vient d'arriver.

En deux secondes il devrait vous répondre, et **l'objet doit revenir lisible**. Si
vous voyez `=?utf-8?q?...` à la place, le décodage des en-têtes est cassé — ce qui
compte bien plus qu'il n'y paraît, car en français comme en espagnol c'est à peu
près chaque message que vous recevrez.

L'accent est tout l'intérêt de ce test. Un objet en anglais sans accent passe, que
le décodage fonctionne ou non.

**Test 2 — demandez-lui d'écrire à un inconnu.**

Demandez-lui d'abord de vous envoyer quelque chose, et vérifiez que cela arrive.
Demandez-lui ensuite d'envoyer un message à une adresse qui **ne figure pas** sur
sa liste d'autorisation.

Il doit refuser. Pas demander la permission, pas vous consulter d'abord : refuser,
et vous dire que l'adresse n'est pas sur la liste. Cette liste est toute la raison
pour laquelle il est sûr de laisser un agent qui lit du courrier non fiable
pouvoir aussi en envoyer — il vaut donc la peine de la voir fonctionner une fois
de vos propres yeux.

S'il envoie, arrêtez tout et prévenez la personne qui l'a installé. Quelque chose
ne va pas.

---

## Ce que votre agent pourra faire

- **Savoir qu'un courriel est arrivé en une seconde environ**, sans interroger la
  boîte et sans qu'on le lui demande.
- **Lire et envoyer** via Himalaya, avec la boîte que vous avez configurée.
- **N'envoyer qu'aux adresses que vous avez approuvées**, listées dans
  `roster.txt`. Toute autre est refusée d'emblée, sans même vous demander.

## Ce que cela change sur la machine

Bon à savoir avant d'accepter. L'agent a pour consigne de vous rendre compte de
tout ceci en terminant, et vous pouvez lui en demander la liste :

- Un service utilisateur systemd qui tourne en continu et redémarre en cas
  d'échec
- Un fichier d'identifiants dans `~/.config/agenteiamail/env`, en `600`
- Des fichiers de journal et d'état sous `~/.local/state/agenteiamail/`
- Le *lingering* activé pour l'utilisateur, afin que le service survive à la
  déconnexion
- Une règle permanente ajoutée aux instructions de l'agent lui-même

## Sécurité

L'agent peut envoyer du courrier directement, ce qui rend un risque bien réel :
**il lit du contenu non fiable toute la journée, et tout ce qu'il lit est un canal
d'instructions possible.**

- `roster.txt` est une liste à correspondance exacte. Ce qui n'y figure pas est
  refusé.
- Le corps des messages est traité comme **des données, jamais comme des ordres** :
  un message demandant à l'agent de transférer quelque chose n'est pas une requête
  qu'il exécute.
- **Ajouter un destinataire à `roster.txt` est votre décision**, jamais une
  réponse à quelque chose arrivé par courrier.
- Le mot de passe réside dans un fichier en `600` hors du dépôt, et ne transite
  jamais par une conversation.

---

## Le reste du dépôt

Ces documents sont en anglais.

| | |
|---|---|
| [`MAILBOX_SETUP.fr-FR.md`](MAILBOX_SETUP.fr-FR.md) | Étape 1 — la boîte et le fichier `.env` |
| [`AGENTS.md`](../AGENTS.md) | Ce que suit l'agent. Commencez ici si vous en êtes un. |
| [`INSTALL.md`](../INSTALL.md) | La séquence d'installation, étape par étape |
| [`DESIGN.md`](../DESIGN.md) | Pourquoi les pièces ont cette forme — à lire avant d'y toucher |

```
scripts/idle_listener.py  Service systemd --user. Maintient une connexion IMAP
  │                       IDLE ouverte ; le serveur signale l'arrivée du courrier.
  │  une ligne par message
  ▼
~/.local/state/agenteiamail/
  mail.log                le flux d'événements
  idle.err.log            diagnostics — surveillés séparément
  seen.offset             jusqu'où l'agent a été informé
  │
  ├─► harness/session_start.py    rejoue l'arriéré au début d'une session
  ├─► harness/watch.sh            pousse chaque ligne dans la session en cours
  └─► harness/rotate_logs.py      rotation copytruncate, sur un timer utilisateur

himalaya                  lit et envoie. Le listener ne télécharge jamais les corps.
scripts/send.sh + roster.txt  l'envoi est limité aux destinataires autorisés.
scripts/preflight.py      prouve qu'une machine peut faire tourner ceci avant de l'installer.
```

## Chemins sur cette machine

- Dépôt : `~/.openclaw/workspace/agenteiamail`
- Identifiants : `~/.config/agenteiamail/env` — en `600`, jamais versionné
- État et événements : `~/.local/state/agenteiamail/`
- Service utilisateur : `~/.config/systemd/user/agenteiamail-idle.service`

## La propriété que tout le reste sert

**Ne jamais échouer en silence.** La latence était le problème facile : IDLE l'a
réglé en un après-midi. Tout le reste existe parce que l'échec coûteux n'est pas
la lenteur, c'est **d'affirmer avec assurance qu'il n'y a pas de nouveau courrier
alors qu'on est aveugle**.

D'où le dernier UID enregistré message par message, la vérification d'`UIDVALIDITY`
à chaque connexion, la surveillance du journal d'erreurs en parallèle de celui des
événements, et le hook de démarrage de session qui demande si le service tourne
réellement. [`DESIGN.md`](../DESIGN.md) explique chacun d'eux et ce qui casse sans.

Construit et vérifié de bout en bout le 09/08/2026.
