# Install_Server_Ubuntu v2.1

Scripts d'installation et de configuration complète d'un serveur Ubuntu sécurisé.

## Table des matières

1. [Présentation](#présentation)
2. [Prérequis](#prérequis)
3. [Installation rapide](#installation-rapide)
4. [Détail des scripts](#détail-des-scripts)
5. [Configuration DNS](#configuration-dns)
6. [Gestion des comptes mail](#gestion-des-comptes-mail)
7. [Gestion des sous-domaines](#gestion-des-sous-domaines)
8. [Sauvegarde et changement de serveur](#sauvegarde-et-changement-de-serveur)
9. [Serveur cloud : Nextcloud + Immich](#serveur-cloud--nextcloud--immich)
10. [Sauvegarde croisée entre les deux serveurs](#sauvegarde-croisée-entre-les-deux-serveurs)
11. [Commandes utiles](#commandes-utiles)
12. [Dépannage](#dépannage)

---

## Présentation

Ce projet automatise la mise en place d'un serveur web + mail + FTP complet sur Ubuntu 22.04 / 24.04
(rôle **web**), ou d'un serveur de stockage perso Nextcloud + Immich (rôle **cloud**, voir
[Serveur cloud](#serveur-cloud--nextcloud--immich)).

| Composant     | Rôle                                          |
|---------------|-----------------------------------------------|
| **Apache**    | Serveur web avec SSL (Let's Encrypt)          |
| **MariaDB**   | Base de données relationnelle                 |
| **PHP**       | Langage serveur + extensions courantes        |
| **phpMyAdmin**| Interface web de gestion de la base           |
| **Postfix**   | Serveur SMTP — envoi et réception de mails    |
| **Dovecot**   | Serveur IMAP/POP3 — lecture des mails         |
| **OpenDKIM**  | Signature DKIM — anti-spam                    |
| **SpamAssassin** | Filtrage anti-spam entrant                 |
| **Fail2Ban**  | Protection brute-force SSH/mail               |
| **Pure-FTPd** | Serveur FTP sécurisé (FTPS + chroot)          |
| **UFW**       | Pare-feu                                      |
| **Nextcloud** | Fichiers, agenda, contacts (rôle cloud)       |
| **Immich**    | Photos et vidéos, remplace Google Photos (rôle cloud) |
| **mdadm / smartd** | Surveillance RAID et disques (rôle cloud) |

---

## Prérequis

- Serveur Ubuntu 22.04 LTS ou 24.04 LTS (VPS ou dédié)
- Accès root (ou `sudo su`)
- Un nom de domaine en `.fr` pointant vers l'IP du serveur
- Port 80 et 443 accessibles (pour Let's Encrypt)

---

## Installation rapide

Sur un VPS ou un serveur dédié OVH installé en Ubuntu, on se connecte en SSH avec le compte
**`ubuntu`** (clé SSH choisie à l'installation) ; root n'est pas accessible en SSH, tout passe par `sudo`.

```bash
# 1. Copier les scripts sur le serveur (depuis votre PC)
scp -r Install_Server_Ubuntu/ ubuntu@<IP_SERVEUR>:~

# 2. Se connecter au serveur
ssh ubuntu@<IP_SERVEUR>

# 3. Rendre les scripts exécutables
chmod +x ~/Install_Server_Ubuntu/*.sh

# 4. Lancer le script principal
sudo bash ~/Install_Server_Ubuntu/install.sh
```

Le script vous pose une série de questions au démarrage :
- **Rôle** : `[1]` web + mail (VPS) ou `[2]` cloud (dédié Nextcloud + Immich)
- **Nom de domaine** (ex : `mondomaine.fr` — le même sur les deux serveurs)
- **Nom d'utilisateur système** : laisser **`ubuntu`** (valeur par défaut) — le compte et sa clé SSH
  ne sont pas modifiés, il reçoit juste les droits sudo s'il ne les a pas
- **Mot de passe** (min. 12 caractères)
- **Nom de la base de données** MariaDB
- **E-mail administrateur**
- **IP publique** du serveur (détectée automatiquement)

Ces informations sont sauvegardées dans `server.conf` et utilisées par tous les sous-scripts.

---

## Détail des scripts

### `install.sh` — Point d'entrée principal

- Vérifie les droits root et la version Ubuntu
- Demande le **rôle** du serveur : **web + mail** (VPS) ou **cloud** (dédié Nextcloud + Immich)
- Recueille la configuration (domaine, utilisateur, mot de passe…)
- Crée l'utilisateur système avec droits sudo
- Présente un **menu interactif** pour choisir les composants à installer (adapté au rôle :
  en rôle cloud, pas de mail, FTP ni WordPress)

### `install_firewall.sh` — Pare-feu UFW

Ouvre uniquement les ports nécessaires :

| Port | Protocole | Service |
|------|-----------|---------|
| 22   | TCP | SSH |
| 80   | TCP | HTTP (Apache) |
| 443  | TCP | HTTPS (Apache + SSL) |
| 25   | TCP | SMTP — réception mails |
| 587  | TCP | SMTP Submission — envoi authentifié |
| 993  | TCP | IMAPS — lecture mails (TLS) |
| 995  | TCP | POP3S — lecture mails (TLS) |
| 21   | TCP | FTP contrôle |
| 20   | TCP | FTP données |
| 40000-50000 | TCP | FTP passif |

### `install_lamp.sh` — Stack LAMP

- Apache avec modules `rewrite`, `ssl`, `headers`, `deflate`
- MariaDB sécurisé + création de la base et de l'utilisateur
- PHP avec extensions : curl, gd, intl, imap, mbstring, xml, zip, apcu, bcmath
- phpMyAdmin (accessible via `https://votre-domaine.fr/phpmyadmin`)
- Certificat SSL Let's Encrypt avec redirection HTTP → HTTPS automatique

### `install_mail.sh` — Serveur de messagerie

Permet d'**envoyer et recevoir** des e-mails avec `@votre-domaine.fr`.

**Postfix** (envoi/réception) :
- Port 25 : réception depuis Internet
- Port 587 : envoi authentifié (clients mail : Thunderbird, Outlook…)
- STARTTLS obligatoire sur port 587

**Dovecot** (stockage/lecture) :
- IMAP sur port 993 (SSL) — recommandé
- POP3 sur port 995 (SSL)
- Stockage Maildir dans `/var/vmail/domaine/utilisateur/`

**OpenDKIM** : signe les mails sortants (améliore la délivrabilité).

**Fail2Ban** : bloque les IP après 5 tentatives de connexion échouées.

### `manage_mail.sh` — Gestion des comptes mail

- Ajout, liste, changement de mot de passe, activation/désactivation, suppression
- Alias / redirections (vers une ou plusieurs adresses)
- Import en masse depuis un fichier texte
- Voir [Gestion des comptes mail](#gestion-des-comptes-mail)

### `manage_subdomains.sh` — Sous-domaines + SSL

- Ajout d'un sous-domaine : site web (dossier dédié) ou proxy vers une appli locale
- Certificat Let's Encrypt + redirection HTTPS automatiques
- Enregistrement DNS créé/supprimé chez OVH si les clés API sont dans `server.conf`
- Suppression propre (VirtualHost, certificat, DNS, fichiers archivés)
- Voir [Gestion des sous-domaines](#gestion-des-sous-domaines)

### `update_dkim_ovh.sh` — Republier la clé DKIM chez OVH

Remplace uniquement l'enregistrement `mail._domainkey` dans la zone OVH, à partir de la clé
privée d'OpenDKIM. Voir [La clé DKIM](#la-clé-dkim).

### `backup_server.sh` / `restore_server.sh` — Sauvegarde et migration

- Une archive chiffrée avec tout ce que les scripts ne recréent pas : bases et comptes MariaDB,
  mails, clé DKIM, sites, FTP, `server.conf` (dont les clés API OVH), sous-domaines, crontabs
- Restauration sur un serveur neuf en 3 commandes, DNS OVH et certificats compris
- Voir [Sauvegarde et changement de serveur](#sauvegarde-et-changement-de-serveur)

### `install_cloud.sh` — Serveur cloud (rôle « cloud »)

- Nextcloud sur `https://cloud.<domaine>` (Apache + mod_php, MariaDB, Redis, cron système)
- Immich sur `https://photos.<domaine>` (Docker, port lié à `127.0.0.1` seulement)
- Surveillance du RAID logiciel (mdadm) et des disques (smartd), alertes par mail
- Alertes envoyées via le serveur mail du VPS (msmtp, compte dédié)
- Fail2Ban pour SSH et les connexions Nextcloud
- Voir [Serveur cloud : Nextcloud + Immich](#serveur-cloud--nextcloud--immich)

### `backup_remote.sh` — Sauvegarde croisée

- Chaque nuit : `backup_server.sh` puis envoi chiffré vers l'autre serveur
- L'envoyeur ne peut que déposer : ni lire, ni effacer, ni écraser ce qui a déjà été reçu
- Voir [Sauvegarde croisée entre les deux serveurs](#sauvegarde-croisée-entre-les-deux-serveurs)

### `install_ftp.sh` — Serveur FTP

- **Pure-FTPd** : FTP avec chroot et mode passif (ports 40000-50000)
- **SFTP** via OpenSSH : accès sécurisé, écriture uniquement dans `/uploads`
- Utilise un compte système dédié (`<SYS_USER>_ftp`), distinct du compte admin

### `install_wordpress.sh` — Installation de WordPress

Installe WordPress sur le VirtualHost du domaine (nécessite `install_lamp.sh` au préalable) :

- **WP-CLI** installé automatiquement
- Base de données MariaDB dédiée (`<DB_NAME>_wp`), distincte de la base du site "vitrine"
- Téléchargement + configuration automatique (`wp-config.php`, clés de sécurité uniques)
- Création du compte administrateur WordPress (mot de passe généré aléatoirement,
  affiché en fin d'installation et sauvegardé dans `server.conf`)
- Permaliens "jolis" (`/%postname%/`)
- Édition de fichiers désactivée depuis l'admin WordPress (`DISALLOW_FILE_EDIT`)
- Détecte automatiquement si un certificat SSL existe déjà pour le domaine
  (posé par Certbot dans `install_lamp.sh`) pour utiliser HTTPS d'office

Si le dossier du site contient déjà des fichiers (par ex. la page d'accueil par
défaut d'`install_lamp.sh`), le script demande confirmation avant de les remplacer.

### Sécuriser SSH (option 6 du menu) — authentification par clé uniquement

Désactive l'authentification SSH par mot de passe (root inclus) pour ne conserver
que la connexion par clé. Le script :

- vérifie qu'une clé SSH est bien présente pour `SYS_USER` avant toute chose
  (sinon il abandonne, pour ne pas vous couper l'accès) ;
- demande une confirmation explicite ;
- valide la nouvelle configuration (`sshd -t`) avant de redémarrer SSH, et
  restaure automatiquement la sauvegarde en cas d'erreur.

⚠️ Testez toujours votre connexion par clé dans un **second terminal**, en
gardant votre session actuelle ouverte, avant de confirmer cette étape.

---

## Configuration DNS

Après l'installation du serveur mail, ajoutez ces enregistrements chez votre hébergeur DNS (OVH, Gandi…) :

```
# Enregistrements de base
A     mail             → <IP_SERVEUR>
MX    @                → 10 mail.votre-domaine.fr.

# SPF : autorise votre serveur à envoyer des mails
TXT   @                → "v=spf1 mx ip4:<IP_SERVEUR> ~all"

# DKIM : clé publique (affichée à la fin de install_mail.sh,
#        ou posée automatiquement par install_dns_ovh.sh — voir plus bas)
TXT   mail._domainkey  → "v=DKIM1; k=rsa; p=<VOTRE_CLE_PUBLIQUE>"

# DMARC : politique de traitement des mails non conformes
TXT   _dmarc           → "v=DMARC1; p=quarantine; rua=mailto:admin@votre-domaine.fr"

# PTR (reverse DNS) : à configurer dans le panel OVH
PTR   <IP_SERVEUR>     → mail.votre-domaine.fr
```

> ⚠️ La propagation DNS peut prendre de quelques minutes à 48h.

### Vérifier la zone DNS (OVH)

```bash
sudo bash install_dns_ovh.sh --verifier     # lecture seule : rien n'est modifié
```

Compare la zone configurée chez OVH (via l'API), ce que publient réellement les serveurs DNS
d'OVH et un résolveur public, avec ce qui est attendu (IP du serveur, clé DKIM locale) :

| Contrôle | Détecte |
|---|---|
| A `@`, `www`, `mail` | absent, mauvaise IP (ancien serveur), en double, AAAA ou CNAME en conflit |
| MX | absent, **MX parasite** (ex : `mx1.mail.ovh.net` laissé par défaut) |
| SPF | absent, **plusieurs SPF** (invalide), IP du serveur non autorisée |
| DKIM | absent, **clé tronquée** (bug OVH), ancienne clé ≠ clé du serveur |
| DMARC | absent ou en double |
| Sous-domaines | enregistrement A manquant pour ceux créés par `manage_subdomains.sh` |
| Publication | le domaine n'utilise pas les DNS OVH, zone pas encore appliquée, propagation |
| Reverse (PTR) | `IP → mail.votre-domaine.fr` absent (à régler dans l'espace client OVH) |
| OpenDKIM | `opendkim-testkey` |

Chaque ligne s'affiche en ✔ / ⚠ / ✖ avec la marche à suivre, puis un bilan. Le code de sortie vaut
1 s'il y a une erreur, ce qui permet une surveillance par cron. La vérification est aussi lancée
automatiquement à la fin de `install_dns_ovh.sh` (remise à zéro), qui recrée désormais aussi les
sous-domaines du serveur.

**Vérification en ligne :**
- Score de délivrabilité : https://mail-tester.com
- Ports ouverts : https://mxtoolbox.com/SuperTool.aspx
- SPF/DKIM/DMARC : https://dmarcian.com/dmarc-inspector/

---

## Gestion des comptes mail

Tout se fait avec `manage_mail.sh` (aussi accessible via l'option **[9]** du menu de `install.sh`).
Les changements sont immédiats, sans redémarrer Postfix ni Dovecot.

### Menu interactif

```bash
sudo bash manage_mail.sh
```

Pour l'adresse, on peut taper juste `prenom` : le domaine principal est ajouté automatiquement.
Laisser le mot de passe vide en génère un aléatoire (affiché une seule fois).

### En ligne de commande

```bash
sudo bash manage_mail.sh add      prenom@votre-domaine.fr          # crée la boîte (mot de passe demandé)
sudo bash manage_mail.sh list                                      # comptes, état, taille, alias
sudo bash manage_mail.sh passwd   prenom@votre-domaine.fr          # change le mot de passe
sudo bash manage_mail.sh disable  prenom@votre-domaine.fr          # bloque (mails conservés)
sudo bash manage_mail.sh enable   prenom@votre-domaine.fr
sudo bash manage_mail.sh delete   prenom@votre-domaine.fr          # supprime (+ boîte et alias, sur confirmation)
sudo bash manage_mail.sh alias    contact@votre-domaine.fr prenom@votre-domaine.fr,autre@votre-domaine.fr
sudo bash manage_mail.sh unalias  contact@votre-domaine.fr
```

### Créer plusieurs comptes d'un coup

```bash
cat > comptes.txt <<EOF
# une ligne par compte — "email" ou "email;motdepasse"
marie@votre-domaine.fr
paul@votre-domaine.fr;UnMotDePasseSolide2026
EOF
sudo bash manage_mail.sh import comptes.txt && shred -u comptes.txt
```

Les mots de passe sont hachés en SHA512-CRYPT et ne passent jamais en argument de commande
(invisibles dans `ps`). Minimum 10 caractères.

> **Autre domaine que le domaine principal ?** Le script propose de l'ajouter, mais il faut
> aussi ses DNS (MX, SPF, DMARC) et une entrée DKIM dans `/etc/opendkim/KeyTable` et
> `SigningTable` : OpenDKIM ne signe par défaut que le domaine principal.

### Configurer un client mail (Thunderbird, Outlook…)

| Paramètre | Valeur |
|-----------|--------|
| Serveur entrant (IMAP) | `mail.votre-domaine.fr` — Port `993` — SSL/TLS |
| Serveur entrant (POP3) | `mail.votre-domaine.fr` — Port `995` — SSL/TLS |
| Serveur sortant (SMTP) | `mail.votre-domaine.fr` — Port `587` — STARTTLS |
| Authentification | Mot de passe normal |
| Nom d'utilisateur | `adresse@votre-domaine.fr` |

---

## Gestion des sous-domaines

Avec `manage_subdomains.sh` (ou l'option **[10]** du menu de `install.sh`). Nécessite la stack LAMP.

```bash
sudo bash manage_subdomains.sh                       # menu
sudo bash manage_subdomains.sh add    blog           # site → /var/www/blog.votre-domaine.fr/public_html
sudo bash manage_subdomains.sh add    app --proxy 3000   # proxy vers 127.0.0.1:3000 (websockets OK)
sudo bash manage_subdomains.sh list                  # état, type, expiration SSL, DNS
sudo bash manage_subdomains.sh ssl    blog           # (re)demande le certificat
sudo bash manage_subdomains.sh delete blog
```

Options : `--no-dns` (ne touche pas au DNS OVH), `--no-ssl` (HTTP seul), `-y` (sans confirmation).

**DNS :** si `install_dns_ovh.sh` a déjà été lancé une fois (clés API OVH enregistrées dans
`server.conf`), l'enregistrement `A` est créé et supprimé automatiquement, et le script attend la
propagation avant de demander le certificat. Sinon, il affiche l'enregistrement à ajouter à la main ;
relancez ensuite `ssl NOM` une fois le DNS propagé.

**Suppression :** retire le VirtualHost (HTTP et HTTPS) et le certificat (plus de renouvellement).
Les fichiers du site ne sont effacés que sur confirmation, après archivage dans
`/root/backups/subdomains/`. `www` et `mail` sont protégés.

---

## Sauvegarde et changement de serveur

Les scripts d'installation recréent la **configuration**, pas les **données**. Pour changer de
serveur dédié, réinstaller un VPS ou simplement avoir une sauvegarde, on passe par
`backup_server.sh` et `restore_server.sh`.

### Ce que contient la sauvegarde

| Élément | Emplacement | Pourquoi c'est important |
|---|---|---|
| `server.conf` | dossier des scripts | Mêmes mots de passe (vmail, MariaDB, WordPress) et **clés API OVH** |
| Bases MariaDB | toutes sauf système | Dont `vmail` : comptes mail, mots de passe, alias |
| Comptes MariaDB | mots de passe hachés + droits | Les sites restaurés se reconnectent sans rien modifier |
| Mails | `/var/vmail` | Contenu des boîtes |
| Clé DKIM | `/etc/dkimkeys`, `/etc/opendkim` | **Même clé = enregistrement DNS DKIM inchangé** |
| Sites | `/var/www` | Site principal, WordPress, sous-domaines |
| FTP | `/home/ftpusers` + mot de passe | Fichiers et identifiants FTP |
| Sous-domaines | liste + type (site / proxy) | Recréés automatiquement, certificats compris |
| Crontabs, VirtualHosts | pour référence | Les VirtualHosts écrits à la main sont signalés |

L'archive est **chiffrée** (AES-256) : elle contient la clé privée DKIM et les secrets de
`server.conf`. **Sans le mot de passe, elle est irrécupérable.**

### Faire une sauvegarde

```bash
sudo bash backup_server.sh                     # ou option [11] du menu de install.sh
# → /home/ubuntu/backups/server_backup_<domaine>_<date>.tar.gz.enc (+ .sha256)
```

Elle est vérifiée (relue en entier) après création ; les 5 plus récentes sont gardées (`--keep N`).
Le dossier et les archives appartiennent au compte `ubuntu` (droits 700/600) : on les récupère
directement en SSH. **Copiez-la hors du serveur** — depuis votre PC :

```bash
scp ubuntu@<IP_ANCIEN_SERVEUR>:backups/server_backup_* .
```

Sauvegarde automatique chaque nuit (le mot de passe est lu dans un fichier lisible par root seul) :

```bash
sudo sh -c 'echo "VotreMotDePasseDArchive" > /root/.backup_pass && chmod 600 /root/.backup_pass'
sudo crontab -e
# 30 3 * * * bash /home/ubuntu/Install_Server_Ubuntu/backup_server.sh --pass-file /root/.backup_pass >> /var/log/backup_server.log 2>&1
```

### Ordre conseillé sur le nouveau serveur

**Avant de commencer — sur l'ancien serveur :**

1. Baisser le TTL DNS à 300 s chez OVH la veille (la bascule sera plus rapide).
2. Faire la sauvegarde **juste avant** la bascule : `sudo bash backup_server.sh`
3. La copier sur votre PC (`scp ubuntu@<ANCIENNE_IP>:backups/server_backup_* .`), puis l'envoyer
   sur le nouveau serveur avec les scripts — toujours avec le compte `ubuntu` :
   ```bash
   scp -r Install_Server_Ubuntu/ server_backup_* ubuntu@<NOUVELLE_IP>:~
   ssh ubuntu@<NOUVELLE_IP>
   cd ~/Install_Server_Ubuntu && chmod +x *.sh
   ```
   > Le nouveau serveur doit avoir votre clé SSH sur le compte `ubuntu` (à choisir lors de
   > l'installation dans l'espace client OVH). La sauvegarde ne touche pas aux clés SSH.

**Sur le nouveau serveur :**

| # | Commande | Ce que ça fait |
|---|---|---|
| 1 | `sudo bash restore_server.sh prepare ~/server_backup_….enc` | Remet `server.conf` (mots de passe + **clés OVH**) et y inscrit la nouvelle IP |
| 2 | `sudo bash install.sh` → **n** à « Reconfigurer » → menu **[5]** — puis **[6]** (SSH par clé) si souhaité | Installe pare-feu, LAMP, mail, FTP avec les **mêmes** mots de passe. Ne **pas** lancer WordPress [7] : il est restauré |
| 3 | `sudo bash restore_server.sh ~/server_backup_….enc` | Restaure bases, mails, **clé DKIM**, sites, FTP, cron ; puis DNS OVH, sous-domaines et certificats (détails ci-dessous) |
| 4 | Espace client OVH → IP → **Modifier le reverse** | PTR `<NOUVELLE_IP>` → `mail.votre-domaine.fr` (indispensable pour ne pas finir en spam) |
| 5 | `sudo bash restore_server.sh ssl` *(si besoin)* | Redemande les certificats manquants une fois le DNS propagé |
| 6 | `sudo bash install_dns_ovh.sh --verifier` | Contrôle complet du DNS (voir [Vérifier la zone DNS](#vérifier-la-zone-dns-ovh)) |
| 7 | Tests | `https://votre-domaine.fr`, un mail vers Gmail, https://mail-tester.com |
| 8 | Ancien serveur | Le garder 24–48 h : des mails peuvent encore y arriver pendant la propagation |

Pendant l'étape 3, dans cet ordre :

1. **DNS OVH** — si les clés API sont dans `server.conf`, le script propose de lancer
   `install_dns_ovh.sh`, qui remet la zone à zéro avec la **nouvelle IP** (A `@`, `www`, `mail`,
   MX, SPF) et la **clé DKIM restaurée**. La zone actuelle est sauvegardée en JSON avant.
2. **Sous-domaines** — recréés juste après, puisque `install_dns_ovh.sh` vient d'effacer leurs
   enregistrements : VirtualHost + enregistrement DNS OVH + certificat.
3. **Certificats** — domaine principal + `www`, `mail.` (Postfix/Dovecot passent du certificat
   auto-signé à Let's Encrypt), FTP et sous-domaines.

> Lors de l'étape 2, `install_lamp.sh` et `install_mail.sh` ne peuvent pas obtenir leurs
> certificats tant que le DNS pointe encore sur l'ancien serveur : c'est normal, l'étape 3
> (ou `restore_server.sh ssl`) s'en charge une fois le DNS basculé.

### La clé API OVH (DNS automatique)

Elle permet à `install_dns_ovh.sh` et `manage_subdomains.sh` de modifier la zone DNS sans passer
par l'interface web d'OVH (qui tronque les longues clés DKIM).

**Première fois** (une seule fois pour toutes) :

1. Créer une application sur https://eu.api.ovh.com/createApp/ → noter
   *Application Key* et *Application Secret*.
2. Lancer `sudo bash install_dns_ovh.sh` : il demande ces deux valeurs, puis affiche un lien
   d'autorisation. L'ouvrir, se connecter à OVH, choisir la durée **Unlimited**, valider.
3. Les trois valeurs sont enregistrées dans `server.conf` :
   ```
   OVH_APP_KEY="…"   OVH_APP_SECRET="…"   OVH_CONSUMER_KEY="…"
   ```
   Les droits sont limités à `/domain/zone/*` (DNS uniquement — pas de facturation, pas de serveurs).

**Sur un nouveau serveur :** rien à refaire — `server.conf` (et donc les clés) revient avec
`restore_server.sh prepare`.

**Si la clé a expiré ou a été révoquée** (erreur HTTP 403 « Invalid credential ») : supprimer la
ligne `OVH_CONSUMER_KEY=` de `server.conf` et relancer `install_dns_ovh.sh` pour en valider une
nouvelle. Les clés actives se gèrent sur https://eu.api.ovh.com/console/ (`/me/api/credential`).

### La clé DKIM

La clé DKIM signe vos mails sortants ; sa partie publique est publiée dans le DNS
(`mail._domainkey.votre-domaine.fr`). Les deux doivent correspondre, sinon Gmail & co
classent vos mails en spam.

- **Avec une sauvegarde** : `restore_server.sh` remet la clé d'origine → l'enregistrement DNS DKIM
  reste valable, rien à changer.
- **Sans sauvegarde** : `install_mail.sh` génère une **nouvelle** clé → il faut republier la clé
  publique, au choix :
  - `sudo bash update_dkim_ovh.sh` — **ne remplace que l'enregistrement DKIM** (recommandé) ;
  - `sudo bash install_dns_ovh.sh` — remet **toute** la zone à zéro ;
  - à la main avec la valeur affichée par `sudo cat /etc/dkimkeys/votre-domaine.fr/mail.txt`.

#### `update_dkim_ovh.sh` — republier seulement la clé DKIM

```bash
sudo bash update_dkim_ovh.sh                 # domaine de server.conf
sudo bash update_dkim_ovh.sh autre-domaine.fr
```

1. recalcule la clé publique depuis `/etc/dkimkeys/<domaine>/mail.private` (la clé réellement
   utilisée par OpenDKIM : correspondance garantie, pas de copier-coller tronqué) ;
2. vérifie que l'accès API fonctionne **avant** de supprimer quoi que ce soit ;
3. supprime les anciens `mail._domainkey` (TXT et type « DKIM » d'OVH), crée le nouveau TXT ;
4. applique la zone (`refresh`).

Les autres enregistrements (A, MX, SPF, DMARC, sous-domaines) ne sont pas touchés. Requiert `jq`
(`sudo apt install jq`).

Identifiants OVH, dans cet ordre : `OVH_APP_KEY` / `OVH_APP_SECRET` / `OVH_CONSUMER_KEY` de
`server.conf`, sinon `~/.ovh.conf` (`OVH_AK` / `OVH_AS` / `OVH_CK`, modèle :
`.ovh.conf.example`, à protéger avec `chmod 600`), sinon les variables d'environnement du même nom.

Vérifier que tout correspond :

```bash
dig TXT mail._domainkey.votre-domaine.fr +short        # clé publiée dans le DNS
sudo opendkim-testkey -d votre-domaine.fr -s mail -vvv  # doit finir par « key OK »
```

---

## Serveur cloud : Nextcloud + Immich

Organisation à deux serveurs pour le même domaine :

| Serveur | Rôle | Contenu |
|---|---|---|
| VPS | `web` | `exemple.fr`, `www`, `mail`, WordPress, FTP, **le mail du domaine** |
| Dédié (ex : KS-5, 2×2 To RAID 1) | `cloud` | `cloud.<domaine>` (Nextcloud), `photos.<domaine>` (Immich) |

Le serveur cloud n'a **pas** de serveur mail : un second MX/SPF pour le même domaine
casserait la délivrabilité. Il envoie ses alertes par le serveur mail du VPS, avec un compte
dédié.

### Installation sur le dédié

À l'installation de l'OS chez OVH/Kimsufi, choisissez **Ubuntu 24.04** et un partitionnement
en **RAID 1 logiciel** sur les deux disques (sinon une panne de disque = perte des données).

```bash
# 1. Sur le VPS : créer le compte qui servira à envoyer les alertes
sudo bash manage_mail.sh add alertes@exemple.fr

# 2. Sur le dédié : copier les scripts, puis
sudo bash install.sh
#   → Rôle : [2] Cloud, domaine : exemple.fr (le même que le VPS)
#   → menu [6] Sécuriser SSH (clé uniquement) — testez d'abord votre clé !
#   → menu [5] Installation complète = pare-feu + LAMP + install_cloud.sh tout
```

`install_cloud.sh tout` enchaîne, en posant ses questions au fur et à mesure :

1. **Alertes** — relais SMTP `mail.<domaine>:587` avec le compte `alertes@…`, mail de test.
2. **RAID + disques** — `MAILADDR` dans `mdadm.conf`, vérification mensuelle du RAID,
   smartd (test court chaque nuit, long le samedi, alerte de température).
3. **Nextcloud** — dernière version (empreinte SHA-256 vérifiée), base `nextcloud`, Redis
   en socket Unix, APCu, OPcache, tâches de fond par cron, réglages en français, mails via le
   relais, HTTPS. Les limites d'envoi (16 Go) sont posées **dans le VirtualHost** : elles ne
   touchent pas aux autres sites.
4. **Immich** — Docker (dépôt officiel), `docker-compose.yml` et `.env` de la dernière
   version, base marquée « disques durs » (`DB_STORAGE_TYPE: 'HDD'`), port `2283`
   **lié à 127.0.0.1** (Docker contourne UFW : sans ça, Immich serait exposé en HTTP), compte
   administrateur créé tout de suite (sinon le premier visiteur pourrait le prendre).
5. **Fail2Ban** — prisons `sshd` et `nextcloud`.

Les identifiants générés (admin Nextcloud et Immich) s'affichent à la fin et sont gardés dans
`server.conf` : **changez-les à la première connexion**.

Chaque étape se relance seule et sans risque (`sudo bash install_cloud.sh nextcloud`…) : elle
ne refait que ce qui manque. C'est aussi ce qu'il faut faire si le certificat n'a pas pu être
obtenu parce que le DNS n'était pas encore propagé.

### DNS

Les enregistrements `cloud` et `photos` (A → IP du dédié) sont créés automatiquement si les
clés API OVH sont connues : le script propose de coller les trois lignes `OVH_*` du
`server.conf` du VPS. Sinon, créez-les à la main dans la zone OVH.

> ⚠ **Ne lancez jamais `install_dns_ovh.sh` sur le serveur cloud** : il remet toute la zone à
> zéro et ferait pointer le site et le mail vers le dédié. Il refuse d'ailleurs de tourner en
> rôle cloud.

### Au quotidien

```bash
sudo bash install_cloud.sh etat          # RAID, santé des disques, espace, services
sudo bash install_cloud.sh test-alertes  # vérifier que les alertes arrivent
sudo bash install_cloud.sh mise-a-jour   # Nextcloud (updater) + Immich (même version majeure)
```

Applis : **Nextcloud** (bureau Windows/Linux, Android, iOS) avec `https://cloud.<domaine>` ;
**Immich** (Android, iOS) avec `https://photos.<domaine>` pour la sauvegarde auto des photos.

Si un disque lâche, `etat` affiche **RAID DÉGRADÉ** et vous recevez un mail : ouvrez un
ticket OVH pour le remplacement, puis réintégrez le disque neuf (`mdadm --add`) selon leur
procédure.

### Ce qui est sauvegardé

`backup_server.sh` sur le serveur cloud inclut la config Nextcloud (`/var/www`) et sa base,
`/opt/immich` (compose + `.env`) et un export de la base Immich (`pg_dumpall`). Les **fichiers**
(`/srv/nextcloud`, `/srv/immich/library`) ne sont **pas** inclus : ce sont plusieurs
centaines de Go, qui ont déjà leurs propres copies (vos appareils, Freebox, disque USB,
kDrive). `--avec-donnees-cloud` les ajoute si besoin. Le RAID protège d'une panne de disque,
**pas** d'une suppression ou d'un piratage.

Pour **changer de serveur cloud**, le plus simple est de copier `/srv` directement d'une
machine à l'autre (`rsync -aH`), puis `restore_server.sh` pour le reste : il affiche les
commandes pour réimporter la base Immich.

---

## Sauvegarde croisée entre les deux serveurs

Chaque serveur envoie chaque nuit sa sauvegarde **chiffrée** sur l'autre, dans un autre
datacenter (VPS à 3 h 30, serveur cloud à 4 h 30) :

```
VPS (web + mail)  ──►  dédié /srv/sauvegardes-archives/web-<domaine>/
dédié (cloud)     ──►  VPS   /srv/sauvegardes-archives/cloud-<domaine>/
```

### Mise en place (une fois par sens)

```bash
# Sur le serveur qui ENVOIE (ex : le VPS)
sudo bash backup_remote.sh configurer
#   → nom (web-<domaine>), IP de l'autre serveur, mot de passe de chiffrement
#   → affiche une commande « autoriser … » à copier

# Sur le serveur qui REÇOIT (ex : le dédié) — coller la commande affichée :
sudo bash backup_remote.sh autoriser web-exemple.fr "ssh-ed25519 AAAA…"

# De retour sur l'envoyeur : valider → test de connexion, tâche cron, premier envoi
```

Puis la même chose dans l'autre sens (configurer sur le dédié, autoriser sur le VPS).

> 🔐 Le mot de passe de chiffrement est dans `/root/.backup_pass` (généré ou choisi).
> **Notez-le dans votre gestionnaire de mots de passe** : si le serveur disparaît, c'est la
> seule façon de relire ses sauvegardes depuis l'autre.

### Ce qu'un serveur piraté peut faire (presque rien)

- La clé SSH de l'envoyeur ne lance que `rrsync -wo -no-del` : **dépôt uniquement** dans son
  dossier. Pas de shell, pas de lecture, pas de `--delete`, pas de `..`.
- Toutes les heures, le receveur (root) **range** les archives terminées dans
  `/srv/sauvegardes-archives/<nom>/`, hors de portée du compte `sauvegarde`. Une archive
  renvoyée avec le même nom est mise de côté (`.doublon-…`) au lieu d'écraser l'originale.
- Le receveur supprime lui-même les archives de plus de 30 jours (`--jours N` pour changer).

### Suivi et restauration

```bash
sudo bash backup_remote.sh etat     # dernier envoi + archives reçues (⚠ si > 36 h)
sudo bash backup_remote.sh envoyer  # envoi immédiat
```

En cas d'échec d'un envoi nocturne, un mail part vers l'adresse admin (journal :
`/var/log/backup_remote.log`).

Pour restaurer un serveur depuis l'autre : copiez l'archive voulue de
`/srv/sauvegardes-archives/<nom>/` (avec son `.sha256`) vers le nouveau serveur, puis suivez
[Ordre conseillé sur le nouveau serveur](#ordre-conseillé-sur-le-nouveau-serveur).

---

## Commandes utiles

```bash
# Logs en temps réel
sudo tail -f /var/log/mail.log          # Logs Postfix + Dovecot
sudo tail -f /var/log/install_server.log # Logs d'installation

# État des services
sudo systemctl status postfix dovecot opendkim pure-ftpd apache2

# Redémarrer les services mail
sudo systemctl restart postfix dovecot opendkim

# Tester l'envoi d'un mail depuis le serveur
echo "Test" | mail -s "Test" votre@email.fr

# File d'attente Postfix
sudo postqueue -p         # Voir les mails en attente
sudo postqueue -f         # Forcer l'envoi
sudo postsuper -d ALL     # Vider la file (en cas de spam)

# Vérifier la configuration Postfix
sudo postfix check

# Vérifier la signature DKIM
sudo opendkim-testkey -d votre-domaine.fr -s mail -vvv

# Bannir/débannir une IP avec Fail2Ban
sudo fail2ban-client status postfix
sudo fail2ban-client set postfix unbanip <IP>
```

---

## Dépannage

### Les mails partent en spam

1. Vérifiez les enregistrements SPF, DKIM, DMARC (voir [Configuration DNS](#configuration-dns))
2. Assurez-vous que le **PTR (reverse DNS)** est configuré chez OVH
3. Testez sur https://mail-tester.com (visez 10/10)
4. Vérifiez que votre IP n'est pas sur une liste noire : https://mxtoolbox.com/blacklists.aspx

### Je ne reçois pas de mails

```bash
# Vérifier que Postfix écoute bien
sudo ss -tlnp | grep :25

# Vérifier les logs
sudo tail -50 /var/log/mail.log

# Tester la réception depuis l'extérieur
telnet mail.votre-domaine.fr 25
```

### Certbot a échoué

- Vérifiez que `mail.votre-domaine.fr` pointe bien vers `<IP_SERVEUR>` en DNS
- Vérifiez que le port 80 est accessible depuis Internet
- Relancez manuellement : `sudo certbot certonly --standalone -d mail.votre-domaine.fr`

### Erreur de connexion SFTP

- Vérifiez que le répertoire racine appartient bien à `root` : `ls -la /home/ftpusers/`
- Consultez les logs SSH : `sudo tail -f /var/log/auth.log`

---

## Licence

Distribué sous licence [MIT](LICENSE) — © 2026 Laurent Lebarbier. Utilisation, modification et
redistribution libres ; les scripts sont fournis « tels quels », sans garantie : relisez-les et
testez-les avant de les lancer sur un serveur en production.

> 🔒 Ne commitez jamais `server.conf`, `.ovh.conf` ni une archive `server_backup_*` : ils
> contiennent mots de passe et clés API (déjà exclus par le `.gitignore`).
