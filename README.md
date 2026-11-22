# Utilitaires d'administration Docker, QEMU/KVM, Caddy et LM Studio

Une collection de scripts pour installer et maintenir quelques services sur un
serveur Ubuntu. Ils sont autonomes, idempotents (on peut les relancer sans
risque) et prudents : vérifications avant chaque action, sauvegardes et retour
arrière quand c'est possible.

| Script | Rôle |
|---|---|
| [`install-docker.sh`](install-docker.sh) | Installe Docker CE depuis le dépôt officiel (Ubuntu, Mint, Pop!_OS…) |
| [`install-qemu.sh`](install-qemu.sh) | Installe QEMU/KVM et libvirt sur Ubuntu 24.04 et ses dérivées |
| [`install-dockhand.sh`](install-dockhand.sh) | Déploie [Dockhand](https://hub.docker.com/r/fnsys/dockhand) (gestion Docker web) via Docker Compose |
| [`setup-caddy-proxies.py`](setup-caddy-proxies.py) | Génère les reverse proxies d'un Caddyfile depuis un fichier YAML |
| [`lmsctl.sh`](lmsctl.sh) | Pilote LM Studio en mode headless (démon `llmster` + unité systemd) |
| [`install-lmstudio.sh`](install-lmstudio.sh) | Installe, met à jour ou arrête proprement LM Studio Desktop (AppImage), avec retour arrière |

## Prérequis

- Ubuntu 22.04 ou 24.04, ou une distribution dérivée.
- Bash 4.4 ou plus récent (Bash 5 est fourni par toutes les versions d'Ubuntu
  supportées).
- Pour `setup-caddy-proxies.py` : Python 3.9 ou plus récent, `python3-yaml` et
  Caddy 2.11.4 ou plus récent.
- Pour `lmsctl.sh` : systemd, sur x86_64 ou arm64, avec `curl`, `libatomic1`
  et `libgomp1`. Sur Debian/Ubuntu, `install` et `update` installent ces trois
  paquets s'ils manquent. Sur les autres distributions, rien n'est installé et
  le script indique quoi installer. L'application desktop LM Studio ne doit pas
  tourner en même temps : les deux partagent `~/.lmstudio`.
- Pour `install-qemu.sh` : Ubuntu 24.04 (`noble`) ou une dérivée basée sur
  Ubuntu 24.04 ; l'accélération matérielle KVM doit être disponible, sauf avec
  l'option `--force`.
- Les droits root (`sudo`) pour tout ce qui modifie le système.

## Installation

```bash
git clone https://github.com/brahimmachkouri/tools.git 
cd tools
chmod +x *.sh *.py
```

Les scripts sont autonomes. Tu peux les lancer depuis ce répertoire ou les
copier un par un dans `/usr/local/sbin`.

## Conventions communes

Tous les scripts partagent la même interface :

- `-h`, `--help` : aide complète (options, variables d'environnement, codes de sortie) ;
- `-V`, `--version` : version du script ;
- messages préfixés : ℹ️ information, ✅ succès, ⚠️ avertissement, ❌ erreur,
  👉 conseil ;
- couleurs seulement si la sortie est un terminal ; `NO_COLOR=1` les désactive ;
- avertissements et erreurs sur stderr, le reste sur stdout ;
- code de sortie `0` en cas de succès, `1` en cas d'échec. Les codes
  particuliers (`2`, `130`…) sont décrits dans l'aide de chaque script.

## Utilisation

### install-qemu.sh

```bash
sudo ./install-qemu.sh                 # QEMU/KVM, libvirt et virt-manager
sudo ./install-qemu.sh --server        # sans interface graphique
sudo ./install-qemu.sh --force         # continue même si KVM est indisponible
./install-qemu.sh --dry-run            # simule sans modifier le système ni sudo
```

Le script installe QEMU, libvirt, OVMF (UEFI) et swtpm (TPM virtuel). Il active
`libvirtd`, configure le réseau NAT `default` et ajoute l'utilisateur ayant
lancé `sudo` aux groupes `libvirt` et `kvm`. Déconnecte-toi puis reconnecte-toi
pour que ces groupes soient pris en compte. Les VM utilisent la connexion
libvirt `qemu:///system`.

`--server` omet `virt-manager`, `virt-viewer` et les paquets graphiques QEMU.
Avec `--force`, l'installation continue même sans KVM, mais les VM seront très
lentes. `--dry-run` ne lance pas `apt-get update` : la simulation s'appuie sur
l'index APT déjà présent.

> ⚠️ Les groupes `libvirt` et `kvm` permettent de piloter les machines
> virtuelles du système : réserve-les aux comptes de confiance.

### install-docker.sh

```bash
./install-docker.sh          # demande confirmation avant de retirer les paquets en conflit
./install-docker.sh --yes    # sans confirmation (automatisation)
```

> ⚠️ Le script ajoute ton utilisateur au groupe `docker`, ce qui donne des
> droits **équivalents à root**.

### install-dockhand.sh

```bash
./install-dockhand.sh                         # 127.0.0.1:3000, données dans /opt/dockhand
./install-dockhand.sh --port 8080 --update    # autre port, et image à jour
DOCKER_INSTALL_SCRIPT=./install-docker.sh ./install-dockhand.sh   # installe Docker si besoin
```

> ⚠️ Dockhand monte `/var/run/docker.sock` : quiconque atteint son interface
> contrôle l'hôte. Crée le compte admin dès le premier accès, et accède-y à
> distance par un tunnel SSH ou un reverse proxy authentifié. Les ports publiés
> par Docker contournent UFW.

### setup-caddy-proxies.py

Le YAML décrit les sites. Le script réécrit uniquement une section délimitée
du Caddyfile et laisse intact tout ce qui a été écrit à la main.

```yaml
settings:
  allowed_networks: [192.168.0.0/16]   # réseaux autorisés pour les sites privés
  max_request_body_size: 20MiB

proxies:
  - hostname: app.example.com
    reverse_to: 10.0.0.5:8080
    access: public
  - hostname: wiki.example.com          # sans 'access' : privé par défaut
    reverse_to: localhost:3000
```

```bash
./setup-caddy-proxies.py proxies.yml --dry-run     # aperçu, sans rien modifier
sudo install -o root -g root -m 0644 proxies.yml /etc/caddy/reverse-proxies.yml
sudo ./setup-caddy-proxies.py /etc/caddy/reverse-proxies.yml   # applique et recharge Caddy
```

Avant d'être installé, le Caddyfile est validé par `caddy validate`. Une
sauvegarde est faite dans `/var/backups/caddy-proxies-from-yaml/`. Si le
rechargement échoue, l'ancien fichier est restauré automatiquement. Les
signatures logicielles (`Server`, `X-Powered-By`, en-têtes ASP.NET) sont
retirées des réponses, y compris des erreurs produites par Caddy lui-même.
Toutes les clés du YAML sont documentées en tête du script.

### lmsctl.sh

Fait tourner LM Studio sans interface graphique, comme un service systemd.

```bash
sudoedit /etc/default/lmstudio-headless   # configuration (exemple ci-dessous)
sudo ./lmsctl.sh check                    # valide la configuration
sudo ./lmsctl.sh install                  # installe llmster et le service
sudo ./lmsctl.sh status
sudo ./lmsctl.sh link                     # état de LM Link et des appareils associés
sudo ./lmsctl.sh configure                # applique une configuration modifiée
sudo ./lmsctl.sh update                   # mise à jour avec retour arrière automatique
./lmsctl.sh help                          # liste des commandes et variables
```

Exemple de `/etc/default/lmstudio-headless` (root:root, mode 0644). Seule
`LMS_USER` est requise, et encore : elle vaut par défaut l'utilisateur qui a
lancé `sudo`.

```bash
LMS_USER=ia
SERVER_PORT=1234
BIND_ADDR=127.0.0.1          # 0.0.0.0 seulement avec authentification et pare-feu
PRELOAD_MODEL=qwen/qwen3-8b  # vide = aucun préchargement
LOAD_ARGS="--context-length 32768 --gpu 1.0"
WATCHDOG_INTERVAL=60         # 0 = pas de surveillance
ENABLE_LM_LINK=true          # voir « LM Link » ci-dessous
```

Toute modification de ce fichier s'applique avec `configure`. Si le service ne
redémarre pas avec la nouvelle configuration, l'ancienne est restaurée.

`sudo ./lmsctl.sh health` renvoie `0` si l'API est saine, `1` si elle est
injoignable, et `2` si le serveur répond mais rejette le jeton. Ces codes
conviennent à une supervision. `install`, `update`, `configure` et `start`
renvoient `3` quand l'API est saine mais que le modèle `PRELOAD_MODEL` n'a pas
pu être chargé : le préchargement n'est pas bloquant et n'annule jamais une
mise à jour.

Un timer systemd (`lmstudio-watchdog.timer`, toutes les `WATCHDOG_INTERVAL`
secondes, 60 par défaut, `0` pour le désactiver) sonde l'API et redémarre le
service après trois sondes sans réponse. Il ignore un service arrêté
volontairement ou en échec, et ne fait rien pendant qu'une commande `lmsctl`
est en cours.

#### LM Link

[LM Link](https://lmstudio.ai/docs/lmlink) permet d'utiliser depuis un autre
appareil, par exemple un portable, les modèles chargés sur ce serveur. Il exige
que le serveur soit connecté une fois à ton compte LM Studio. `lmsctl` ne le
fait pas à ta place, car la connexion est interactive :

```bash
sudo -u ia -H ~ia/.lmstudio/bin/lms login   # « ia » = LMS_USER ; une seule fois
# puis ENABLE_LM_LINK=true dans /etc/default/lmstudio-headless
sudo ./lmsctl.sh configure
sudo ./lmsctl.sh link
```

`link` (également affiché par `status`) indique si LM Link est en ligne,
pourquoi il ne l'est pas, par exemple faute de connexion au compte, et l'état
de chaque appareil associé :

```
── LM Link ──
✅ LM Link en ligne — cet appareil : iam
   Appareils connectés : 1 sur 3
     truc.local                           ⚪ déconnecté
     pop-os                               🟢 connecté
```

Il renvoie `0` si LM Link est en ligne et `1` sinon. Un appareil éteint n'est
pas une panne du serveur et ne change pas ce code. LM Link est réactivé à
chaque démarrage du service, avec une attente limitée à 20 s : un réseau
indisponible ne retarde jamais l'API locale. La surveillance de l'API ne
redémarre jamais le service à cause de LM Link.

### install-lmstudio.sh

```bash
sudo ./install-lmstudio.sh              # installe LM Studio, ou le met à jour s'il est déjà là
sudo ./install-lmstudio.sh --force      # réinstalle la même version
sudo ./install-lmstudio.sh --rollback   # revient à la version précédente
sudo ./install-lmstudio.sh --stop       # arrête proprement LM Studio, sans rien installer
```

L'AppImage est installée dans `/opt/lmstudio` (modifiable avec `LMSTUDIO_DIR`).
Aucun raccourci de bureau n'est créé. Lors d'une mise à jour, la nouvelle
version est téléchargée et vérifiée **avant** l'arrêt de LM Studio. En cas
d'échec, l'installation en place reste intacte.

Pour arrêter LM Studio, le script décharge d'abord les modèles et arrête le
serveur API avec le CLI `lms` de l'utilisateur qui fait tourner l'application.
Il envoie ensuite SIGTERM, puis SIGKILL si l'application ne s'est pas fermée
au bout de 15 s.

## Sécurité

Ces scripts tournent en root. Ils évitent donc de faire confiance à leur
environnement :

- les fichiers de configuration exécutés ou lus en root doivent appartenir à
  root et ne pas être modifiables par autrui ;
- les services sont exposés en local par défaut (127.0.0.1) ;
- les téléchargements sont contrôlés avant usage (taille, format, contenu
  attendu).

Lis l'aide (`--help`) de chaque script avant de l'utiliser en production.

## Contribuer

Les scripts Bash doivent passer [ShellCheck](https://www.shellcheck.net)
sans avertissement :

```bash
sudo apt install shellcheck
shellcheck *.sh
python3 -m py_compile setup-caddy-proxies.py
```

`lmsctl.sh` a aussi des tests unitaires, qui tournent sans root, sans réseau et
sans systemd (Linux, Bash ≥ 4.4) :

```bash
sudo apt install bats
bats tests/
```

Ces contrôles sont relancés automatiquement à chaque push et pull request
(`.github/workflows/lint.yml`).

## Licence

Distribué sous licence MIT : voir [LICENSE](LICENSE).
