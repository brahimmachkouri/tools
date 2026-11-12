#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""setup-caddy-proxies.py — synchronise des reverse proxies Caddy depuis un YAML.

Le fichier YAML est la source de vérité d'une section délimitée du Caddyfile.
Tout ce qui se trouve en dehors des marqueurs de gestion est conservé tel quel,
ce qui permet de cohabiter avec une configuration écrite à la main.

Exemple de fichier YAML :

    settings:
      allowed_networks:
        - 192.168.0.0/16
      outside_redirect_url: https://www.example.com/
      outside_redirect_status: 302
      max_request_body_size: 20MiB
      set_x_real_ip: true

    proxies:
      - hostname: app.example.com
        reverse_to: app.internal.example:8080
        access: public
      - hostname: wiki.example.com
        reverse_to: localhost:3000
        access: private
      - hostname: depot.example.com
        reverse_to: localhost:5000
        access: private
        max_request_body_size: 500MiB   # surcharge, ce site seul
      - hostname: glpi.example.com
        reverse_to: 10.10.20.15:80      # IP privée de Nginx Proxy Manager
        upstream_host: glpi.local.example.com
        access: private

Utilisation :

    setup-caddy-proxies.py proxies.yml --dry-run
    sudo install -o root -g root -m 0644 proxies.yml \\
        /etc/caddy/reverse-proxies.yml
    sudo setup-caddy-proxies.py \\
        /etc/caddy/reverse-proxies.yml            # applique et recharge
    setup-caddy-proxies.py -V                     # affiche la version

Le script est idempotent : relancé sans changement dans le YAML, il ne touche
ni au fichier ni au service.

Structure du YAML :
  - 'proxies' (obligatoire) : la liste des sites. La racine peut aussi être
    directement cette liste, sans bloc 'settings'.
  - 'settings' (optionnel) : les réglages appliqués à tous les sites.
Chaque site accepte 'hostname', 'reverse_to', 'access' et 'upstream_host', et
peut redéfinir n'importe quel réglage de 'settings' pour lui seul.

Réglages (dans 'settings' ou par site) :
  - allowed_networks : liste de réseaux CIDR autorisés pour les sites privés ;
  - outside_redirect_url : URL de redirection des clients non autorisés ;
    vide (défaut) => réponse 403 ;
  - outside_redirect_status : code de la redirection (défaut : 302) ;
  - max_request_body_size : taille maximale du corps des requêtes (défaut 20MiB) ;
  - set_x_real_ip : ajoute l'en-tête X-Real-IP vers l'upstream (défaut : true).

Le mode d'accès se choisit site par site avec la clé 'access' :
  - public  : accessible depuis n'importe quelle adresse ;
  - private : réservé aux réseaux de 'allowed_networks'.
Si 'access' est absent, le site est privé : un oubli ne publie donc jamais une
application par erreur. Un site privé exige au moins un réseau autorisé (global
ou par site), sinon le script s'arrête. allowed_networks, outside_redirect_url
et outside_redirect_status sont refusés sur un site public, où ils n'ont aucun
effet.

En-tête Host vers l'upstream (clé 'upstream_host', par site uniquement) :
  Par défaut, Caddy transmet à l'upstream le Host demandé par le client
  (par exemple glpi.example.com). Si l'upstream est lui-même un reverse proxy
  qui choisit l'application d'après le Host (Nginx Proxy Manager, Traefik...),
  il ne reconnaît pas ce nom et affiche sa page par défaut. 'upstream_host'
  force alors le Host envoyé :
    - un nom d'hôte (ex. glpi.local.example.com) : envoyé tel quel ;
    - la valeur spéciale 'upstream' : reprend l'hôte de 'reverse_to'
      (sans le port).
  Le script génère : header_up Host <valeur>. Caddy continue d'envoyer le nom
  demandé par le client dans X-Forwarded-Host.

Les options --allowed-networks, --redirect-url, --max-body-size et --public ont
été retirées dans la version 2.7.0 : ces réglages vivent maintenant dans le YAML.

La section générée contient un snippet Caddyfile commun qui supprime les
en-têtes Server, X-Powered-By et les signatures ASP.NET, y compris sur les
erreurs produites par Caddy lui-même (502, 413...). Chaque site importe
ce snippet et filtre aussi explicitement ces en-têtes à la sortie de son
upstream. L'option --explicit-http-redirects permet d'appliquer la même
politique aux redirections HTTP vers HTTPS gérées explicitement par le script.

Compatibilité cible : Caddy 2.11.4 ou version ultérieure. Le matcher client_ip
est utilisé pour le filtrage et pour X-Real-IP. Sans proxy frontal de confiance,
client_ip correspond à l'adresse de la connexion directe et les en-têtes
X-Forwarded-* fournis par le client ne deviennent pas une source de confiance.

Si Caddy est placé derrière un autre reverse proxy, sa plage exacte doit être
déclarée dans le bloc global du Caddyfile avec trusted_proxies static et
trusted_proxies_strict. Ce script préserve ce bloc mais ne le génère pas, car
faire confiance automatiquement à un réseau trop large serait dangereux.

Par sécurité, les directives import situées hors de la section gérée sont
refusées : leur contenu empêcherait de garantir l'absence de hostname dupliqué.
L'import du snippet de masquage est accepté parce qu'il est entièrement généré
et contenu dans la section gérée.
En mode application, le YAML et le Caddyfile doivent être des fichiers
ordinaires appartenant à root et non modifiables par le groupe ou par tous.

Nom historique : ce script s'appelait « caddy-proxies-from-yaml ». Ce nom est
conservé dans les marqueurs de la section gérée, le verrou et le répertoire
de sauvegarde, afin de rester compatible avec les machines déjà configurées.

Dépendance Debian/Ubuntu : apt install python3-yaml
L'historique des versions est tenu dans CHANGELOG.md.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import datetime as dt
import fcntl
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import stat as stat_module
import subprocess
import sys
import tempfile
from typing import NoReturn
from urllib.parse import urlsplit

# ---------------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------------
# Même convention que les scripts Bash du projet : un emoji par type de
# message, des couleurs seulement si le flux est un terminal et que NO_COLOR
# (https://no-color.org) n'est pas défini, avertissements et erreurs sur
# stderr. La sortie de --dry-run (le Caddyfile) reste brute.

SCRIPT_NAME = os.path.basename(sys.argv[0]) or "setup-caddy-proxies.py"


def _paint(stream: object, color: str, text: str) -> str:
    """Entoure 'text' d'une couleur ANSI si 'stream' est un terminal."""
    isatty = getattr(stream, "isatty", None)
    if isatty is not None and isatty() and not os.environ.get("NO_COLOR"):
        return f"\033[{color}m{text}\033[0m"
    return text


def log(message: str) -> None:
    """Message brut sur stdout."""
    print(message)


def info(message: str) -> None:
    """Information sur stdout."""
    print(_paint(sys.stdout, "34", f"ℹ️  {message}"))


def ok(message: str) -> None:
    """Succès sur stdout."""
    print(_paint(sys.stdout, "32", f"✅ {message}"))


def warn(message: str) -> None:
    """Avertissement sur stderr."""
    print(_paint(sys.stderr, "33", f"⚠️  {message}"), file=sys.stderr)


def err(message: str) -> None:
    """Erreur sur stderr."""
    print(_paint(sys.stderr, "31", f"❌ {message}"), file=sys.stderr)


def fail(message: str, exit_code: int = 1) -> NoReturn:
    """Affiche une erreur puis quitte avec 'exit_code'."""
    err(message)
    raise SystemExit(exit_code)


try:
    import yaml
except ImportError:
    fail(
        "le module Python 'yaml' est absent. "
        "Installe-le avec : apt install python3-yaml"
    )


# Numéro de version (MAJEUR.MINEUR.CORRECTIF). À incrémenter à chaque
# modification et à reporter dans CHANGELOG.md. Il est affiché par
# -V / --version et écrit dans l'en-tête de la section générée.
__version__ = "2.9.0"


# ---------------------------------------------------------------------------
# Constantes et valeurs par défaut
# ---------------------------------------------------------------------------

DEFAULT_CADDYFILE = Path("/etc/caddy/Caddyfile")
CADDY_BIN = Path("/usr/bin/caddy")
SYSTEMCTL_BIN = Path("/usr/bin/systemctl")

# Les marqueurs délimitent la zone réécrite à chaque exécution. Ils doivent
# rester stables dans le temps : les changer sur une machine déjà configurée
# ferait perdre le lien avec la section existante.
BEGIN_MARKER = "# BEGIN MANAGED BY caddy-proxies-from-yaml"
END_MARKER = "# END MANAGED BY caddy-proxies-from-yaml"
SIGNATURE_SNIPPET_NAME = "hide_software_signatures"
SIGNATURE_HEADERS = (
    "Server",
    "X-Powered-By",
    "X-AspNet-Version",
    "X-AspNetMvc-Version",
)

# Aucun contrôle d'accès n'est embarque par défaut. Tous les réglages sont
# lus dans le YAML : globalement via 'settings', et surchargeables par site.
ACCESS_PUBLIC = "public"
ACCESS_PRIVATE = "private"
ACCESS_VALUES = (ACCESS_PUBLIC, ACCESS_PRIVATE)
# Valeur appliquée quand la clé 'access' est absente : le choix le plus sur.
DEFAULT_ACCESS = ACCESS_PRIVATE

# Valeur spéciale de 'upstream_host' : reprendre l'hôte de 'reverse_to'.
UPSTREAM_HOST_FROM_REVERSE_TO = "upstream"

# Valeurs par défaut des réglages, appliquées quand ni 'settings' ni le site
# ne les précisent.
DEFAULT_MAX_BODY_SIZE = "20MiB"
DEFAULT_REDIRECT_STATUS = 302
DEFAULT_SET_X_REAL_IP = True

# Clés acceptées dans 'settings' et en surcharge par site (snake_case).
SETTING_KEYS = frozenset({
    "allowed_networks",
    "outside_redirect_url",
    "outside_redirect_status",
    "max_request_body_size",
    "set_x_real_ip",
})
# Réglages sans effet sur un site public : les accepter par site laisserait
# croire a une restriction inexistante.
PRIVATE_ONLY_SETTING_KEYS = frozenset({
    "allowed_networks",
    "outside_redirect_url",
    "outside_redirect_status",
})
# Clés propres a un site, refusées dans 'settings' : elles décrivent un
# upstream précis et n'ont pas de sens pour tous les sites à la fois.
SITE_ONLY_KEYS = frozenset({"upstream_host"})

# Les sauvegardes sont volontairement placées hors de /etc/caddy. Elles ne
# peuvent donc pas être chargées accidentellement par une directive import.
BACKUP_ROOT = Path("/var/backups/caddy-proxies-from-yaml")
MAX_BACKUPS = 20
MAX_BACKUPS_ALLOWED = 1000
MAX_YAML_BYTES = 1024 * 1024
MAX_CADDYFILE_BYTES = 8 * 1024 * 1024
MAX_PROXIES = 1000
COMMAND_TIMEOUT_SECONDS = 60
MAX_COMMAND_OUTPUT_CHARS = 16 * 1024

# Verrou pose pendant la phase lecture -> écriture, pour éviter que deux
# exécutions simultanées ne s'écrasent mutuellement.
LOCK_PATH = Path("/run/caddy-proxies-from-yaml.lock")

# Un hostname de site doit être un FQDN : Caddy a besoin d'un nom public pour
# obtenir un certificat. Les jokers (*.example.com) ne sont pas acceptés ici.
FQDN_RE = re.compile(
    r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z"
)

# L'hôte d'un upstream est plus permissif : un nom court (localhost, backend)
# est parfaitement légitime pour une machine interne ou un conteneur.
SHORT_HOSTNAME_RE = re.compile(r"(?=.{1,253}\Z)[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\Z")

BODY_SIZE_RE = re.compile(
    r"[1-9][0-9]{0,8}(?:B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)\Z"
)

# La ligne de date générée change à chaque exécution. Elle est neutralisée
# avant comparaison pour que le script reste idempotent (cf. is_equivalent).
GENERATED_LINE_RE = re.compile(r"^#\s*Genere le .*$\n?", re.MULTILINE)


class ConfigError(Exception):
    """Erreur de données ou de structure de configuration."""


@dataclass(frozen=True)
class Settings:
    """Réglages effectifs d'un site, après fusion défaut -> global -> site."""

    allowed_networks: tuple[str, ...]
    redirect_url: str
    redirect_status: int
    max_body_size: str
    set_x_real_ip: bool


DEFAULT_SETTINGS = Settings(
    allowed_networks=(),
    redirect_url="",
    redirect_status=DEFAULT_REDIRECT_STATUS,
    max_body_size=DEFAULT_MAX_BODY_SIZE,
    set_x_real_ip=DEFAULT_SET_X_REAL_IP,
)


@dataclass(frozen=True)
class Proxy:
    """Un reverse proxy décrit dans le YAML, avec ses réglages effectifs."""

    hostname: str
    upstream: str
    access: str
    allowed_networks: tuple[str, ...]
    redirect_url: str
    redirect_status: int
    max_body_size: str
    set_x_real_ip: bool
    # En-tête Host forcé vers l'upstream ; chaîne vide = Host du client.
    upstream_host: str = ""

    @property
    def is_public(self) -> bool:
        """Vrai si le site est accessible depuis n'importe quelle adresse."""
        return self.access == ACCESS_PUBLIC


@dataclass(frozen=True)
class FileSnapshot:
    """État exact d'un fichier avant son remplacement."""

    data: bytes
    device: int
    inode: int
    size: int
    mtime_ns: int
    mode: int
    uid: int
    gid: int
    digest: str


class StrictSafeLoader(yaml.SafeLoader):
    """SafeLoader sans alias YAML et refusant les clés dupliquées."""

    def compose_node(self, parent: object, index: object) -> yaml.Node:
        """Refuse les alias YAML (bombes « billion laughs », références cachées)."""
        if self.check_event(yaml.AliasEvent):
            event = self.peek_event()
            raise yaml.constructor.ConstructorError(
                None,
                None,
                "les alias YAML ne sont pas autorisés",
                event.start_mark,
            )
        return super().compose_node(parent, index)

    def construct_mapping(
        self, node: yaml.MappingNode, deep: bool = False
    ) -> dict[object, object]:
        """Construit un objet YAML en refusant les clés dupliquées."""
        self.flatten_mapping(node)
        mapping: dict[object, object] = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                duplicate = key in mapping
            except TypeError as exc:
                raise yaml.constructor.ConstructorError(
                    "pendant la lecture d'un objet YAML",
                    node.start_mark,
                    "une clé YAML non hachable a été trouvée",
                    key_node.start_mark,
                ) from exc
            if duplicate:
                raise yaml.constructor.ConstructorError(
                    "pendant la lecture d'un objet YAML",
                    node.start_mark,
                    f"clé dupliquée : {key!r}",
                    key_node.start_mark,
                )
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def safe_display(value: object) -> str:
    """Neutralise les caractères de contrôle dans les messages et commentaires."""
    text = str(value)
    result: list[str] = []
    for character in text:
        codepoint = ord(character)
        if character in "\r\n" or not character.isprintable():
            if codepoint <= 0xFF:
                result.append(f"\\x{codepoint:02x}")
            else:
                result.append(f"\\u{codepoint:04x}")
        else:
            result.append(character)
    return "".join(result)


def safe_command_output(value: str) -> str:
    """Neutralise les contrôles terminaux et borne les diagnostics externes."""
    truncated = len(value) > MAX_COMMAND_OUTPUT_CHARS
    value = value[:MAX_COMMAND_OUTPUT_CHARS]
    result: list[str] = []
    for character in value:
        codepoint = ord(character)
        if character in "\n\t":
            result.append(character)
        elif character.isprintable():
            result.append(character)
        elif codepoint <= 0xFF:
            result.append(f"\\x{codepoint:02x}")
        else:
            result.append(f"\\u{codepoint:04x}")
    if truncated:
        result.append("\n[sortie tronquée]")
    return "".join(result).strip()


def positive_integer(value: str) -> int:
    """Type argparse de --keep-backups : entier entre 1 et MAX_BACKUPS_ALLOWED."""
    if not re.fullmatch(r"[0-9]{1,6}", value):
        raise argparse.ArgumentTypeError("un entier positif est attendu")
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("la valeur doit être supérieure ou égale à 1")
    if number > MAX_BACKUPS_ALLOWED:
        raise argparse.ArgumentTypeError(
            f"la valeur ne doit pas dépasser {MAX_BACKUPS_ALLOWED}"
        )
    return number


# ---------------------------------------------------------------------------
# Ligne de commande
# ---------------------------------------------------------------------------


def usage_text() -> str:
    """Texte de l'aide, au même format que les scripts Bash du projet."""
    return f"""\
{SCRIPT_NAME} {__version__} — synchronise des reverse proxies Caddy depuis un YAML

Usage : [sudo] {SCRIPT_NAME} <fichier.yml> [options]

Arguments :
  <fichier.yml>               fichier YAML (bloc 'settings' optionnel + liste
                              'proxies')

Options :
  --caddyfile <chemin>        chemin du Caddyfile (défaut : {DEFAULT_CADDYFILE}) ;
                              un chemin personnalisé exige --no-reload
  --explicit-http-redirects   génère un bloc HTTP par hostname afin de supprimer
                              les signatures sur les redirections HTTP vers HTTPS
  --keep-backups <n>          nombre de sauvegardes conservées
                              (défaut : {MAX_BACKUPS}, maximum : {MAX_BACKUPS_ALLOWED})
  --dry-run                   affiche le Caddyfile résultant sans rien modifier
                              (ni root ni verrou nécessaires)
  --no-reload                 modifie et valide le Caddyfile sans recharger Caddy
  -h, --help                  affiche cette aide et quitte
  -V, -v, --version           affiche la version et quitte

Variables d'environnement :
  NO_COLOR                    désactive les couleurs si elle est définie

Codes de sortie :
  0  Caddyfile à jour (modifié ou déjà conforme), ou --dry-run réussi
  1  échec : YAML invalide, validation Caddy refusée, rechargement impossible…
  2  erreur d'utilisation (option inconnue, argument manquant)

Fichiers :
  {BACKUP_ROOT}/   sauvegardes du Caddyfile
  {LOCK_PATH}       verrou d'exécution

Notes :
  - Sans --dry-run, le script doit être lancé en root ; le YAML et le
    Caddyfile doivent alors appartenir à root et ne pas être modifiables par
    le groupe ou par tous.
  - Le format du YAML est décrit en tête du script et dans le README.
"""


# Traduction des messages d'erreur les plus courants d'argparse, qui sont en
# anglais par défaut. Un message absent de la liste est affiché tel quel.
ARGPARSE_MESSAGES = (
    (re.compile(r"^the following arguments are required: (.*)$"),
     r"argument(s) obligatoire(s) manquant(s) : \1"),
    (re.compile(r"^unrecognized arguments: (.*)$"),
     r"argument(s) non reconnu(s) : \1"),
    (re.compile(r"^argument (\S+): expected one argument$"),
     r"l'option \1 attend une valeur"),
    (re.compile(r"^ambiguous option: (.*)$"),
     r"option ambiguë : \1"),
    (re.compile(r"^argument (\S+): (.*)$"),
     r"option \1 : \2"),
)


class HelpParser(argparse.ArgumentParser):
    """ArgumentParser dont l'aide et les erreurs suivent la convention du projet."""

    def format_help(self) -> str:
        """Renvoie le texte de --help."""
        return usage_text()

    def error(self, message: str) -> NoReturn:
        """Affiche une erreur d'utilisation en français et quitte avec le code 2."""
        for pattern, replacement in ARGPARSE_MESSAGES:
            message = pattern.sub(replacement, message)
        print(f"Usage : {SCRIPT_NAME} <fichier.yml> [options]", file=sys.stderr)
        print(f"Aide  : {SCRIPT_NAME} --help", file=sys.stderr)
        fail(message, exit_code=2)


def parse_args() -> argparse.Namespace:
    """Analyse la ligne de commande (code de sortie 2 en cas d'erreur)."""
    parser = HelpParser(prog=SCRIPT_NAME)
    parser.add_argument(
        "yaml_file",
        metavar="fichier.yml",
        type=Path,
        help="fichier YAML (bloc 'settings' optionnel + liste 'proxies')",
    )
    parser.add_argument(
        "--caddyfile",
        type=Path,
        default=DEFAULT_CADDYFILE,
        help=f"chemin du Caddyfile (défaut : {DEFAULT_CADDYFILE})",
    )
    # Options retirées (v2.7.0) : conservées masquées pour afficher un message
    # clair aux anciennes invocations (cron, unités systemd...). Les réglages
    # correspondants se placent maintenant dans le bloc 'settings' du YAML.
    parser.add_argument("--allowed-networks", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--redirect-url", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--max-body-size", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--public", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--explicit-http-redirects",
        action="store_true",
        help=(
            "génère un bloc HTTP par hostname afin de supprimer les signatures "
            "sur les redirections HTTP vers HTTPS"
        ),
    )
    parser.add_argument(
        "--keep-backups",
        type=positive_integer,
        default=MAX_BACKUPS,
        help=f"nombre de sauvegardes conservées (défaut : {MAX_BACKUPS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="affiche le Caddyfile résultant sans rien modifier",
    )
    parser.add_argument(
        "--no-reload",
        action="store_true",
        help="modifie et valide le Caddyfile sans recharger Caddy",
    )
    # L'action 'version' affiche la version puis quitte, avant la vérification
    # des arguments obligatoires : '-V' fonctionne donc sans fichier YAML.
    # '-v' est conservé pour compatibilité avec la version 2.8.0.
    parser.add_argument(
        "-V",
        "-v",
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
        help="affiche la version du script et quitte",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Validation des données YAML
# ---------------------------------------------------------------------------


def validate_fqdn(value: str, field: str) -> str:
    """Valide un nom de domaine complet (au moins un point)."""
    name = value.strip().rstrip(".").lower()
    if not FQDN_RE.fullmatch(name):
        raise ConfigError(f"{field} invalide : {value!r}")
    return name


def validate_upstream_host(value: str, field: str) -> str:
    """Valide l'hôte d'un upstream : nom court, FQDN ou adresse IP.

    Contrairement au hostname du site, un upstream pointe souvent vers
    localhost, vers un nom de conteneur ou vers une IP privée. Refuser ces
    formes serait la principale source de faux rejets.
    """
    host = value.strip().rstrip(".")

    # Adresse IP littérale : on la normalise via le module ipaddress, qui
    # rejette au passage les formes ambiguës (0177.0.0.1, 10.1, etc.).
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        pass

    lowered = host.lower()
    if not SHORT_HOSTNAME_RE.fullmatch(lowered):
        raise ConfigError(f"{field} invalide : {value!r}")
    # Un label vide (double point) ou un tiret en bord de label reste possible
    # avec la regex permissive ci-dessus : on vérifie label par label.
    for label in lowered.split("."):
        if not label or len(label) > 63 or label.startswith("-") or label.endswith("-"):
            raise ConfigError(f"{field} invalide : {value!r}")
    return lowered


def validate_port(value: str, field: str) -> int:
    """Valide un numéro de port TCP (1-65535) écrit en décimal."""
    if not re.fullmatch(r"[0-9]{1,5}", value):
        raise ConfigError(f"{field} : port non numérique : {value!r}")
    port = int(value)
    if not 1 <= port <= 65535:
        raise ConfigError(f"{field} : port hors limites : {port}")
    return port


def validate_upstream(value: object, index: int) -> str:
    """Valide un 'reverse-to' au format hôte:port.

    Formes acceptées : 10.0.0.1:8080, backend:3000, srv.internal.example:443 et
    [2001:db8::1]:8080 (les crochets sont obligatoires en IPv6, sinon le
    dernier deux-points serait ambigu).
    """
    field = f"entrée {index}: 'reverse_to'"
    if not isinstance(value, str):
        raise ConfigError(f"{field} doit être une chaîne")

    candidate = value.strip()

    if candidate.startswith("["):
        closing = candidate.find("]")
        if closing == -1 or not candidate[closing + 1 :].startswith(":"):
            raise ConfigError(f"{field} : format IPv6 attendu : [adresse]:port")
        raw_host = candidate[1:closing]
        raw_port = candidate[closing + 2 :]
        try:
            host = str(ipaddress.IPv6Address(raw_host))
        except ValueError as exc:
            raise ConfigError(f"{field} : adresse IPv6 invalide : {raw_host!r}") from exc
        port = validate_port(raw_port, field)
        return f"[{host}]:{port}"

    raw_host, separator, raw_port = candidate.rpartition(":")
    if not separator:
        raise ConfigError(f"{field} doit respecter le format hôte:port")

    # "2001:db8::1:8080" est ambigu : impossible de savoir si 8080 est un port
    # ou le dernier groupe de l'adresse. On exige les crochets.
    if ":" in raw_host:
        raise ConfigError(
            f"{field} : une adresse IPv6 doit être entre crochets : [adresse]:port"
        )

    host = validate_upstream_host(raw_host, f"{field} : hôte")
    port = validate_port(raw_port, field)
    return f"{host}:{port}"


def upstream_host_part(upstream: str) -> str:
    """Extrait l'hôte d'un upstream déjà valide ('hôte:port' ou '[ipv6]:port').

    Les crochets d'une adresse IPv6 sont conservés : c'est la forme exigée
    dans un en-tête Host.
    """
    if upstream.startswith("["):
        return upstream[: upstream.index("]") + 1]
    return upstream.rpartition(":")[0]


def validate_upstream_host_header(value: object, index: int, upstream: str) -> str:
    """Valide la clé 'upstream_host' et renvoie le Host à envoyer à l'upstream.

    Accepte un nom d'hôte (court ou FQDN), une adresse IP, ou la valeur
    spéciale 'upstream' qui reprend l'hôte de 'reverse_to'. Le port n'est pas
    accepté : les reverse proxies choisissent le site d'après le nom seul.
    """
    field = f"entrée {index}: 'upstream_host'"
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(
            f"{field} doit être un nom d'hôte ou {UPSTREAM_HOST_FROM_REVERSE_TO!r} "
            f"(valeur reçue : {safe_display(repr(value))})"
        )
    candidate = value.strip()
    if candidate == UPSTREAM_HOST_FROM_REVERSE_TO:
        return upstream_host_part(upstream)
    if ":" in candidate and not candidate.startswith("["):
        # Soit un port (glpi.local:80), soit une IPv6 sans crochets : dans les
        # deux cas on refuse avec un message qui dit quoi faire.
        try:
            ipaddress.IPv6Address(candidate)
        except ValueError:
            raise ConfigError(
                f"{field} : indique le nom seul, sans port : {value!r}"
            ) from None
        return f"[{ipaddress.IPv6Address(candidate)}]"
    if candidate.startswith("["):
        if not candidate.endswith("]"):
            raise ConfigError(f"{field} : indique l'adresse IPv6 seule, sans port")
        try:
            return f"[{ipaddress.IPv6Address(candidate[1:-1])}]"
        except ValueError as exc:
            raise ConfigError(f"{field} : adresse IPv6 invalide : {value!r}") from exc
    return validate_upstream_host(candidate, field)


def validate_redirect_url(value: str) -> str:
    """Accepte uniquement une URL HTTP(S) absolue représentable par un token Caddy."""
    if value == "":
        return ""

    forbidden = {'{', '}', '"', "'", "`", "\\", "#"}
    if any(character.isspace() or not character.isprintable() for character in value):
        raise ConfigError("l'URL de redirection contient un espace ou caractère de contrôle")
    if any(character in forbidden for character in value):
        raise ConfigError("l'URL de redirection contient un caractère interdit par sécurité")

    try:
        parsed = urlsplit(value)
        # L'accès à .port déclenche aussi la validation syntaxique du port.
        _ = parsed.port
    except ValueError as exc:
        raise ConfigError(f"URL de redirection invalide : {value!r}") from exc

    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        raise ConfigError("l'URL de redirection doit être une URL HTTP(S) absolue")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigError("l'URL de redirection ne doit pas contenir d'identifiants")
    return value


def secure_open_flags() -> int:
    """Drapeaux d'ouverture en lecture qui refusent de suivre un lien symbolique."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if no_follow is None:
        raise ConfigError("O_NOFOLLOW n'est pas disponible sur ce système")
    return flags | no_follow


def read_fd_limited(fd: int, maximum: int, label: str) -> bytes:
    """Lit tout le descripteur 'fd' en refusant de dépasser 'maximum' octets."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(fd, min(65536, maximum + 1 - total))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > maximum:
            raise ConfigError(f"{label} dépasse la taille maximale de {maximum} octets")


def check_secure_regular_file(info: os.stat_result, path: Path, label: str) -> None:
    """Exige un fichier ordinaire appartenant à root, non modifiable par autrui."""
    if not stat_module.S_ISREG(info.st_mode):
        raise ConfigError(f"{label} n'est pas un fichier ordinaire : {safe_display(path)}")
    if info.st_uid != 0:
        raise ConfigError(
            f"{label} doit appartenir à root : {safe_display(path)} "
            f"(UID actuel : {info.st_uid})"
        )
    if info.st_mode & (stat_module.S_IWGRP | stat_module.S_IWOTH):
        raise ConfigError(
            f"{label} est modifiable par le groupe ou par tous : {safe_display(path)}"
        )


def validate_access(value: object, index: int) -> str:
    """Valide la clé 'access' : 'public' ou 'private', en minuscules."""
    field = f"entrée {index}: 'access'"
    # Le type est vérifié avant tout : YAML transforme par exemple 'yes' ou
    # 'on' en booléen, ce qui doit être refusé clairement.
    if not isinstance(value, str) or value not in ACCESS_VALUES:
        raise ConfigError(
            f"{field} doit valoir {ACCESS_PUBLIC!r} ou {ACCESS_PRIVATE!r} "
            f"(valeur reçue : {safe_display(repr(value))})"
        )
    return value


def validate_bool(value: object, field: str) -> bool:
    """Exige un vrai booléen YAML (true/false), pas 'yes' ni 1."""
    if not isinstance(value, bool):
        raise ConfigError(
            f"{field} doit être un booléen true/false "
            f"(valeur reçue : {safe_display(repr(value))})"
        )
    return value


def validate_networks_list(value: object, context: str) -> tuple[str, ...]:
    """Valide une liste de réseaux CIDR issue du YAML."""
    field = f"{context}: 'allowed_networks'"
    if not isinstance(value, list) or not value:
        raise ConfigError(f"{field} doit être une liste non vide de réseaux CIDR")
    networks: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise ConfigError(
                f"{field} : chaque réseau doit être une chaîne "
                f"(valeur reçue : {safe_display(repr(item))})"
            )
        try:
            # strict=False accepte 10.0.0.1/24 en plus de 10.0.0.0/24.
            networks.append(str(ipaddress.ip_network(item, strict=False)))
        except ValueError as exc:
            raise ConfigError(f"{field} : réseau invalide : {item!r}") from exc
    return tuple(networks)


def validate_redirect_status(value: object, context: str) -> int:
    """Valide 'outside_redirect_status' : un entier 3xx."""
    field = f"{context}: 'outside_redirect_status'"
    # bool est un sous-type de int : on l'exclut pour ne pas accepter true/false.
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(
            f"{field} doit être un entier 3xx "
            f"(valeur reçue : {safe_display(repr(value))})"
        )
    if not 300 <= value <= 399:
        raise ConfigError(f"{field} doit être un code de redirection 3xx (reçu : {value})")
    return value


def require_str(value: object, field: str) -> str:
    """Exige une chaîne YAML ; l'erreur cite le champ et la valeur reçue."""
    if not isinstance(value, str):
        raise ConfigError(
            f"{field} doit être une chaîne "
            f"(valeur reçue : {safe_display(repr(value))})"
        )
    return value


def validate_redirect_url_value(value: object, context: str) -> str:
    """Valide 'outside_redirect_url' en préfixant l'erreur par son contexte."""
    field = f"{context}: 'outside_redirect_url'"
    value = require_str(value, field)
    try:
        return validate_redirect_url(value)
    except ConfigError as exc:
        raise ConfigError(f"{field} : {exc}") from exc


def validate_body_size_value(value: object, context: str) -> str:
    """Valide 'max_request_body_size' en préfixant l'erreur par son contexte."""
    field = f"{context}: 'max_request_body_size'"
    value = require_str(value, field)
    if not BODY_SIZE_RE.fullmatch(value):
        raise ConfigError(
            f"{field} invalide ; exemples acceptés : 1024B, 20MiB, 2GiB"
        )
    return value


def parse_settings_overrides(raw: dict, *, context: str) -> dict:
    """Valide les clés de réglage présentes et renvoie les surcharges internes.

    'raw' ne contient que des clés de réglage (SETTING_KEYS). Le dictionnaire
    renvoyé utilise les noms de champs de Settings.
    """
    overrides: dict[str, object] = {}
    if "allowed_networks" in raw:
        overrides["allowed_networks"] = validate_networks_list(
            raw["allowed_networks"], context
        )
    if "outside_redirect_url" in raw:
        overrides["redirect_url"] = validate_redirect_url_value(
            raw["outside_redirect_url"], context
        )
    if "outside_redirect_status" in raw:
        overrides["redirect_status"] = validate_redirect_status(
            raw["outside_redirect_status"], context
        )
    if "max_request_body_size" in raw:
        overrides["max_body_size"] = validate_body_size_value(
            raw["max_request_body_size"], context
        )
    if "set_x_real_ip" in raw:
        overrides["set_x_real_ip"] = validate_bool(
            raw["set_x_real_ip"], f"{context}: 'set_x_real_ip'"
        )
    return overrides


def load_proxies(
    yaml_path: Path, *, require_secure_permissions: bool
) -> list[Proxy]:
    """Ouvre une seule fois, contrôle puis analyse le YAML."""
    try:
        fd = os.open(yaml_path, secure_open_flags())
    except OSError as exc:
        raise ConfigError(
            f"ouverture impossible du YAML {safe_display(yaml_path)}: {exc}"
        ) from exc

    try:
        info = os.fstat(fd)
        if not stat_module.S_ISREG(info.st_mode):
            raise ConfigError(f"le YAML n'est pas un fichier ordinaire : {safe_display(yaml_path)}")
        if require_secure_permissions:
            check_secure_regular_file(info, yaml_path, "le fichier YAML")
        if info.st_size > MAX_YAML_BYTES:
            raise ConfigError(
                f"le YAML dépasse la taille maximale de {MAX_YAML_BYTES} octets"
            )
        raw = read_fd_limited(fd, MAX_YAML_BYTES, "le fichier YAML")
        info_after = os.fstat(fd)
        if (
            info_after.st_dev != info.st_dev
            or info_after.st_ino != info.st_ino
            or info_after.st_size != info.st_size
            or info_after.st_mtime_ns != info.st_mtime_ns
        ):
            raise ConfigError("le fichier YAML a change pendant sa lecture")
    finally:
        os.close(fd)

    try:
        text = raw.decode("utf-8")
        data = yaml.load(text, Loader=StrictSafeLoader)
    except UnicodeError as exc:
        raise ConfigError(f"le YAML n'est pas encode en UTF-8 : {exc}") from exc
    except (yaml.YAMLError, RecursionError) as exc:
        raise ConfigError(f"YAML invalide dans {safe_display(yaml_path)}: {exc}") from exc

    if isinstance(data, list):
        settings_raw: dict = {}
        proxies_raw: object = data
    elif isinstance(data, dict):
        if not all(isinstance(key, str) for key in data):
            raise ConfigError("les clés de premier niveau doivent être des chaînes")
        unknown_root = set(data) - {"settings", "proxies"}
        if unknown_root:
            raise ConfigError(
                "clé(s) de premier niveau inconnue(s) : "
                + ", ".join(sorted(unknown_root))
                + " (attendu : 'settings' et 'proxies')"
            )
        if "proxies" not in data:
            raise ConfigError("la clé 'proxies' est obligatoire à la racine du YAML")
        settings_raw = data.get("settings") or {}
        if not isinstance(settings_raw, dict):
            raise ConfigError("'settings' doit être un objet YAML")
        if not all(isinstance(key, str) for key in settings_raw):
            raise ConfigError("les clés de 'settings' doivent être des chaînes")
        site_only = sorted(set(settings_raw) & SITE_ONLY_KEYS)
        if site_only:
            raise ConfigError(
                "clé(s) à placer sur un site, pas dans 'settings' : "
                + ", ".join(site_only)
            )
        unknown_settings = set(settings_raw) - SETTING_KEYS
        if unknown_settings:
            raise ConfigError(
                "réglage(s) inconnu(s) dans 'settings' : "
                + ", ".join(sorted(unknown_settings))
            )
        proxies_raw = data["proxies"]
    else:
        raise ConfigError(
            "la racine du YAML doit être une liste de sites, ou un objet "
            "contenant 'proxies' (et un 'settings' optionnel)"
        )

    if not isinstance(proxies_raw, list) or not proxies_raw:
        raise ConfigError("'proxies' doit être une liste non vide de sites")
    if len(proxies_raw) > MAX_PROXIES:
        raise ConfigError(f"le YAML contient plus de {MAX_PROXIES} reverse proxies")

    global_settings = replace(
        DEFAULT_SETTINGS, **parse_settings_overrides(settings_raw, context="settings")
    )

    proxies: list[Proxy] = []
    seen_hostnames: set[str] = set()
    base_keys = (
        {"hostname", "access", "reverse_to", "reverse-to"}
        | set(SETTING_KEYS)
        | set(SITE_ONLY_KEYS)
    )

    for index, item in enumerate(proxies_raw, start=1):
        if not isinstance(item, dict):
            raise ConfigError(f"entrée {index}: un objet YAML est attendu")
        if not all(isinstance(key, str) for key in item):
            raise ConfigError(f"entrée {index}: toutes les clés doivent être des chaînes")

        keys = set(item)
        if "hostname" not in keys:
            raise ConfigError(f"entrée {index}: champ manquant : 'hostname'")

        has_new = "reverse_to" in keys
        has_old = "reverse-to" in keys
        if has_new and has_old:
            raise ConfigError(
                f"entrée {index}: indique 'reverse_to' seul, pas aussi 'reverse-to'"
            )
        if not has_new and not has_old:
            raise ConfigError(f"entrée {index}: champ manquant : 'reverse_to'")
        if has_old:
            warn(
                f"entrée {index}: la clé 'reverse-to' est dépréciée ; "
                "renomme-la 'reverse_to'"
            )

        # Les champs inconnus sont refusés plutôt qu'ignorés : une faute de
        # frappe dans une clé produirait sinon un proxy silencieusement absent.
        extra = keys - base_keys
        if extra:
            raise ConfigError(
                f"entrée {index}: champ(s) inconnu(s) : {', '.join(sorted(extra))}"
            )

        raw_hostname = item["hostname"]
        if not isinstance(raw_hostname, str):
            raise ConfigError(f"entrée {index}: 'hostname' doit être une chaîne")
        hostname = validate_fqdn(raw_hostname, f"entrée {index}: hostname")
        if hostname in seen_hostnames:
            raise ConfigError(f"hostname dupliqué dans le YAML : {hostname}")

        upstream = validate_upstream(
            item["reverse_to"] if has_new else item["reverse-to"], index
        )
        access = validate_access(item.get("access", DEFAULT_ACCESS), index)

        upstream_host = ""
        if "upstream_host" in item:
            upstream_host = validate_upstream_host_header(
                item["upstream_host"], index, upstream
            )

        site_raw = {key: item[key] for key in item if key in SETTING_KEYS}
        # Un site public ignore le filtrage : autoriser ces clés par site
        # laisserait croire a une restriction qui n'existe pas.
        if access == ACCESS_PUBLIC:
            misplaced = sorted(set(site_raw) & PRIVATE_ONLY_SETTING_KEYS)
            if misplaced:
                raise ConfigError(
                    f"entrée {index} ({hostname}): site public ; ces réglages ne "
                    "s'appliquent qu'aux sites privés : " + ", ".join(misplaced)
                )
        settings = replace(
            global_settings,
            **parse_settings_overrides(site_raw, context=f"entrée {index}"),
        )

        if access == ACCESS_PRIVATE and not settings.allowed_networks:
            raise ConfigError(
                f"entrée {index} ({hostname}): site privé sans réseau autorisé ; "
                "définis 'allowed_networks' dans 'settings' ou sur ce site "
                "(un site sans clé 'access' est privé)"
            )

        seen_hostnames.add(hostname)
        proxies.append(
            Proxy(
                hostname=hostname,
                upstream=upstream,
                access=access,
                allowed_networks=settings.allowed_networks,
                redirect_url=settings.redirect_url,
                redirect_status=settings.redirect_status,
                max_body_size=settings.max_body_size,
                set_x_real_ip=settings.set_x_real_ip,
                upstream_host=upstream_host,
            )
        )

    # Tri par hostname : la sortie ne depend plus de l'ordre des entrées du
    # YAML, donc réorganiser le fichier source ne déclenche pas de rechargement
    # inutile de Caddy.
    proxies.sort(key=lambda entry: entry.hostname)
    return proxies


# ---------------------------------------------------------------------------
# Génération de la section gérée
# ---------------------------------------------------------------------------


def render_managed_section(
    proxies: list[Proxy],
    *,
    source: Path,
    explicit_http_redirects: bool = False,
) -> str:
    """Produit le texte complet de la section gérée, marqueurs compris."""
    generated_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    source_name = safe_display(source.name)
    header = (
        f"{BEGIN_MARKER}\n"
        "# Section generee automatiquement : toute modification manuelle sera\n"
        "# perdue a la prochaine synchronisation.\n"
        f"# Source YAML : {source_name}\n"
        f"# Genere le {generated_at} par caddy-proxies-from-yaml {__version__}\n"
    )

    snippet_lines = [
        f"({SIGNATURE_SNIPPET_NAME}) {{",
        "\theader {",
    ]
    snippet_lines.extend(f"\t\t-{field}" for field in SIGNATURE_HEADERS)
    # Les erreurs produites par Caddy lui-même (502 upstream injoignable, 413
    # corps trop gros...) ne passent pas par le bloc header ci-dessus : sans
    # handle_errors, elles portaient « Server: Caddy ». Aucune réponse n'est
    # écrite ici : le statut et le corps vide d'origine sont conservés.
    snippet_lines.extend(["\t}", "\thandle_errors {", "\t\theader {"])
    snippet_lines.extend(f"\t\t\t-{field}" for field in SIGNATURE_HEADERS)
    snippet_lines.extend(["\t\t}", "\t}", "}"])
    snippet = "\n".join(snippet_lines)

    blocks: list[str] = []
    for proxy in proxies:
        hostname = proxy.hostname
        upstream = proxy.upstream
        # Le commentaire d'accès précède le premier bloc généré pour ce site.
        access_comment = f"# Acces : {proxy.access}"
        if explicit_http_redirects:
            http_lines = [
                access_comment,
                f"http://{hostname} {{",
                f"\timport {SIGNATURE_SNIPPET_NAME}",
                "",
                f"\tredir https://{hostname}{{uri}} 308",
                "}",
            ]
            blocks.append("\n".join(http_lines))

        lines = [] if explicit_http_redirects else [access_comment]
        lines += [
            f"{hostname} {{",
            f"\timport {SIGNATURE_SNIPPET_NAME}",
            "",
        ]

        if not proxy.is_public:
            # Garde-fou : load_proxies refuse déjà un site privé sans réseau,
            # mais on ne génère jamais un bloc privé sans filtrage.
            if not proxy.allowed_networks:
                raise ConfigError(
                    f"le site privé {hostname} n'a aucun réseau autorisé"
                )
            # Avec Caddy 2.11.4, client_ip vaut l'adresse du pair direct tant
            # qu'aucun trusted_proxies n'est configure. Derriere un proxy
            # frontal, seuls ses CIDR exacts doivent être déclarés dans le
            # bloc global, avec trusted_proxies_strict.
            lines.append(
                f"\t@forbidden not client_ip {' '.join(proxy.allowed_networks)}"
            )
            lines.append("")
            if proxy.redirect_url:
                lines.append(
                    f"\tredir @forbidden {proxy.redirect_url} {proxy.redirect_status}"
                )
            else:
                lines.append("\trespond @forbidden 403")
            lines.append("")

        lines.append("\trequest_body {")
        lines.append(f"\t\tmax_size {proxy.max_body_size}")
        lines.append("\t}")
        lines.append("")
        lines.append(f"\treverse_proxy {upstream} {{")
        # Caddy transmet par défaut le Host du client, ainsi que
        # X-Forwarded-For, X-Forwarded-Host et X-Forwarded-Proto.
        # 'upstream_host' remplace le Host pour les upstreams qui aiguillent
        # d'après ce nom (Nginx Proxy Manager...) ; X-Forwarded-Host garde le
        # nom demandé par le client. X-Real-IP reste optionnel (set_x_real_ip).
        if proxy.upstream_host:
            lines.append(f"\t\theader_up Host {proxy.upstream_host}")
        if proxy.set_x_real_ip:
            lines.append("\t\theader_up X-Real-IP {client_ip}")
        for field in SIGNATURE_HEADERS:
            lines.append(f"\t\theader_down -{field}")
        lines.append("\t}")
        lines.append("")
        lines.append("\tlog")
        lines.append("}")
        blocks.append("\n".join(lines))

    return (
        header
        + "\n"
        + snippet
        + "\n\n"
        + "\n\n".join(blocks)
        + f"\n\n{END_MARKER}"
    )


def scan_caddy_structure(content: str) -> list[tuple[str, str, int, bool]]:
    """Retourne (ligne brute, partie structurelle, profondeur, dans-littéral).

    Ce mini-lexer ne cherche pas à remplacer l'adaptateur officiel de Caddy. Il
    sert seulement à ne pas confondre accolades/commentaires contenus dans une
    chaîne ou un heredoc avec la structure des blocs.
    """
    scanned: list[tuple[str, str, int, bool]] = []
    quote: str | None = None
    heredoc_end: str | None = None
    depth = 0

    for raw_with_ending in content.splitlines(keepends=True):
        raw = raw_with_ending.rstrip("\r\n")
        literal_before = quote is not None or heredoc_end is not None

        if heredoc_end is not None:
            first_token = raw.strip().split(maxsplit=1)
            if first_token and first_token[0] == heredoc_end:
                heredoc_end = None
            scanned.append((raw_with_ending, "", depth, literal_before))
            continue

        output: list[str] = []
        index = 0
        while index < len(raw):
            character = raw[index]
            if quote is not None:
                if quote == '"' and character == "\\" and index + 1 < len(raw):
                    index += 2
                    continue
                if character == quote:
                    quote = None
                index += 1
                continue

            if character == "#":
                break
            if character in {'"', "`"}:
                quote = character
                index += 1
                continue

            output.append(character)
            index += 1

        structural = "".join(output)
        depth_before = depth
        scanned.append((raw_with_ending, structural, depth_before, literal_before))
        depth += structural.count("{") - structural.count("}")

        if quote is None:
            heredoc = re.search(r"(?:^|\s)<<([^\s]+)(?=\s|$)", structural)
            if heredoc:
                heredoc_end = heredoc.group(1)

    return scanned


def split_managed_section(current: str) -> tuple[str, str, bool]:
    """Sépare le Caddyfile en (avant, après, marqueurs_presents)."""
    scanned = scan_caddy_structure(current)
    begin_indexes: list[int] = []
    end_indexes: list[int] = []

    for index, (raw, _structural, depth, in_literal) in enumerate(scanned):
        line = raw.rstrip("\r\n")
        if depth == 0 and not in_literal and line == BEGIN_MARKER:
            begin_indexes.append(index)
        elif depth == 0 and not in_literal and line == END_MARKER:
            end_indexes.append(index)

    if len(begin_indexes) != len(end_indexes):
        raise ConfigError("un seul des deux marqueurs de gestion est présent")
    if len(begin_indexes) > 1:
        raise ConfigError("plusieurs sections gérées ont été détectées")
    if not begin_indexes:
        return current, "", False
    if begin_indexes[0] >= end_indexes[0]:
        raise ConfigError("les marqueurs de gestion sont dans le mauvais ordre")

    before = "".join(item[0] for item in scanned[: begin_indexes[0]])
    after = "".join(item[0] for item in scanned[end_indexes[0] + 1 :])
    return before, after, True


def normalise_site_token(token: str) -> str | None:
    """Réduit une adresse de site Caddy à son nom d'hôte.

    Gere les formes https://example.com, example.com:8443, example.com/chemin et
    [2001:db8::1]:443. Renvoie None si le token ne contient rien d'exploitable.
    """
    token = token.strip().strip(",")
    if not token:
        return None

    for scheme in ("https://", "http://"):
        if token.startswith(scheme):
            token = token[len(scheme) :]
            break

    # Une adresse peut porter un chemin : example.com/api
    token = token.split("/", maxsplit=1)[0]

    if token.startswith("["):
        closing = token.find("]")
        if closing == -1:
            return None
        token = token[1:closing]
    else:
        # Retire le port seulement si ce qui suit le dernier deux-points est
        # bien numérique, pour ne pas amputer une adresse IPv6 sans crochets.
        head, separator, tail = token.rpartition(":")
        if separator and tail.isdigit() and head:
            token = head

    token = token.rstrip(".").lower()
    return token or None


def site_addresses_outside_managed_section(content: str) -> set[str]:
    """Extrait les adresses des blocs de site déclarés hors section gérée.

    Seules les ouvertures de bloc au niveau racine sont examinées. Cela détecte
    aussi un bloc de site indenté, sans confondre un bloc reverse_proxy interne.
    """
    addresses: set[str] = set()
    for raw, structural, depth, in_literal in scan_caddy_structure(content):
        if depth != 0 or in_literal:
            continue
        line = structural.strip()
        if not line.endswith("{"):
            continue
        address_part = line[:-1].strip()
        if not address_part:
            # Bloc d'options globales : "{" seul sur la ligne.
            if raw.lstrip().startswith("{"):
                continue
            raise ConfigError(
                "une adresse de site citée ou dynamique hors section gérée "
                "ne peut pas être vérifiée de facon sure"
            )
        if "{" in address_part or "}" in address_part:
            raise ConfigError(
                "une adresse de site dynamique hors section gérée ne peut pas "
                "être vérifiée de facon sure"
            )
        for token in re.split(r"[\s,]+", address_part):
            normalised = normalise_site_token(token)
            if normalised:
                addresses.add(normalised)
    return addresses


def reject_imports(content: str) -> None:
    """Refuse les imports dont les hostnames ne peuvent pas être inventoriés."""
    for _raw, structural, _depth, in_literal in scan_caddy_structure(content):
        if not in_literal and re.match(r"^\s*import(?:\s|$)", structural):
            raise ConfigError(
                "le Caddyfile contient une directive 'import' hors de la section "
                "gérée. Pour garantir la détection des doublons, ces imports ne "
                "sont pas pris en charge"
            )


def has_top_level_snippet(content: str, name: str) -> bool:
    """Détecte une définition de snippet au niveau racine du Caddyfile."""
    pattern = re.compile(rf"^\s*\({re.escape(name)}\)\s*\{{\s*$")
    return any(
        depth == 0 and not in_literal and pattern.fullmatch(structural) is not None
        for _raw, structural, depth, in_literal in scan_caddy_structure(content)
    )


def build_candidate(
    current: str,
    proxies: list[Proxy],
    *,
    source: Path,
    explicit_http_redirects: bool = False,
) -> str:
    """Assemble le futur Caddyfile complet à partir de l'actuel."""
    before, after, has_managed_section = split_managed_section(current)
    # Le "\n" évite de coller la dernière ligne de 'before' à la première de
    # 'after' lors de l'analyse.
    unmanaged = before + "\n" + after

    reject_imports(unmanaged)
    if has_top_level_snippet(unmanaged, SIGNATURE_SNIPPET_NAME):
        raise ConfigError(
            f"le snippet ({SIGNATURE_SNIPPET_NAME}) existe déjà hors de la "
            "section gérée ; renomme-le ou supprime-le pour éviter une collision"
        )

    existing_addresses = site_addresses_outside_managed_section(unmanaged)
    duplicates = sorted(
        proxy.hostname for proxy in proxies if proxy.hostname in existing_addresses
    )
    if duplicates:
        raise ConfigError(
            "hostname(s) déjà configuré(s) hors de la section gérée : "
            + ", ".join(duplicates)
        )

    managed = render_managed_section(
        proxies,
        source=source,
        explicit_http_redirects=explicit_http_redirects,
    )

    if not has_managed_section:
        # Première exécution : la section est ajoutée à la fin du fichier.
        prefix = current.rstrip()
        return f"{prefix}\n\n{managed}\n" if prefix else f"{managed}\n"

    prefix = before.rstrip()
    suffix = after.lstrip("\n")
    candidate = f"{prefix}\n\n{managed}\n" if prefix else f"{managed}\n"
    if suffix:
        candidate += f"\n{suffix}"
    return candidate


def is_equivalent(candidate: str, current: str) -> bool:
    """Compare deux Caddyfiles en ignorant la ligne de date de génération.

    Sans cette normalisation, la date rendrait chaque exécution différente de
    la précédente et provoquerait un rechargement de Caddy à chaque appel.
    """
    return GENERATED_LINE_RE.sub("", candidate) == GENERATED_LINE_RE.sub("", current)


# ---------------------------------------------------------------------------
# Écriture, validation, rechargement
# ---------------------------------------------------------------------------


def absolute_path(path: Path) -> Path:
    """Produit un chemin absolu normalise sans suivre les liens symboliques."""
    return Path(os.path.abspath(os.fspath(path)))


def check_secure_directory(directory: Path, label: str) -> None:
    """Exige que 'directory' et tous ses parents soient des répertoires root,
    non modifiables par autrui, sans lien symbolique sur le chemin."""
    try:
        resolved = directory.resolve(strict=True)
    except OSError as exc:
        raise ConfigError(f"contrôle impossible de {safe_display(directory)}: {exc}") from exc
    if resolved != directory:
        raise ConfigError(f"{label} ne doit traverser aucun lien symbolique")

    current = directory
    while True:
        try:
            info = os.lstat(current)
        except OSError as exc:
            raise ConfigError(f"contrôle impossible de {safe_display(current)}: {exc}") from exc
        if not stat_module.S_ISDIR(info.st_mode) or info.st_uid != 0:
            raise ConfigError(
                f"{label} et ses parents doivent être des répertoires appartenant à root"
            )
        if info.st_mode & (stat_module.S_IWGRP | stat_module.S_IWOTH):
            raise ConfigError(
                f"{label} ou l'un de ses parents est modifiable par le groupe ou par tous"
            )
        if current == current.parent:
            break
        current = current.parent


def read_caddyfile(
    path: Path, *, require_secure_permissions: bool
) -> tuple[str, FileSnapshot]:
    """Lit le Caddyfile de façon sûre et renvoie (texte, instantané exact).

    L'instantané permet ensuite de détecter toute modification concurrente."""
    if require_secure_permissions:
        check_secure_directory(path.parent, "le répertoire du Caddyfile")
    try:
        fd = os.open(path, secure_open_flags())
    except OSError as exc:
        raise ConfigError(
            f"ouverture impossible du Caddyfile {safe_display(path)}: {exc}"
        ) from exc

    try:
        info = os.fstat(fd)
        if not stat_module.S_ISREG(info.st_mode):
            raise ConfigError(f"le Caddyfile n'est pas un fichier ordinaire : {safe_display(path)}")
        if require_secure_permissions:
            check_secure_regular_file(info, path, "le Caddyfile")
        if info.st_size > MAX_CADDYFILE_BYTES:
            raise ConfigError(
                f"le Caddyfile dépasse la taille maximale de {MAX_CADDYFILE_BYTES} octets"
            )
        data = read_fd_limited(fd, MAX_CADDYFILE_BYTES, "le Caddyfile")
        info_after = os.fstat(fd)
        if (
            info_after.st_dev != info.st_dev
            or info_after.st_ino != info.st_ino
            or info_after.st_size != info.st_size
            or info_after.st_mtime_ns != info.st_mtime_ns
        ):
            raise ConfigError("le Caddyfile a change pendant sa lecture")
    finally:
        os.close(fd)

    try:
        content = data.decode("utf-8")
    except UnicodeError as exc:
        raise ConfigError(f"le Caddyfile n'est pas encode en UTF-8 : {exc}") from exc

    snapshot = FileSnapshot(
        data=data,
        device=info.st_dev,
        inode=info.st_ino,
        size=info.st_size,
        mtime_ns=info.st_mtime_ns,
        mode=info.st_mode,
        uid=info.st_uid,
        gid=info.st_gid,
        digest=hashlib.sha256(data).hexdigest(),
    )
    return content, snapshot


def assert_caddyfile_unchanged(caddyfile: Path, expected: FileSnapshot) -> None:
    """Lève ConfigError si le Caddyfile ne correspond plus à 'expected'."""
    _content, current = read_caddyfile(caddyfile, require_secure_permissions=True)
    expected_state = (
        expected.device,
        expected.inode,
        expected.size,
        expected.mtime_ns,
        expected.mode,
        expected.uid,
        expected.gid,
        expected.digest,
    )
    current_state = (
        current.device,
        current.inode,
        current.size,
        current.mtime_ns,
        current.mode,
        current.uid,
        current.gid,
        current.digest,
    )
    if current_state != expected_state:
        raise ConfigError(
            "le Caddyfile a été modifié par un autre processus pendant "
            "l'opération ; aucune modification n'a été appliquée"
        )


def check_trusted_executable(path: Path, label: str) -> Path:
    """Exige un exécutable ordinaire appartenant à root, non modifiable par autrui."""
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise ConfigError(f"{label} introuvable à l'emplacement {path}: {exc}") from exc
    if not stat_module.S_ISREG(info.st_mode):
        raise ConfigError(f"{label} n'est pas un fichier exécutable ordinaire : {path}")
    if info.st_uid != 0 or info.st_mode & (stat_module.S_IWGRP | stat_module.S_IWOTH):
        raise ConfigError(f"{label} doit appartenir à root et ne pas être modifiable par autrui")
    if not info.st_mode & stat_module.S_IXUSR:
        raise ConfigError(f"{label} n'est pas exécutable : {path}")
    return path


def run_command(command: list[str | Path]) -> subprocess.CompletedProcess[str]:
    """Exécute une commande par chemin absolu, avec environnement minimal et
    délai maximal ; stdout et stderr sont réunis."""
    executable = Path(command[0])
    if not executable.is_absolute():
        raise ConfigError("refus d'exécuter une commande avec un chemin non absolu")
    # Ne rien heriter de l'appelant : ce programme est normalement execute en
    # root et ni Caddy ni systemctl n'ont besoin de variables utilisateur.
    environment = {
        "HOME": "/root",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    }
    try:
        return subprocess.run(
            [os.fspath(item) for item in command],
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
            env=environment,
            cwd="/",
        )
    except subprocess.TimeoutExpired as exc:
        raise ConfigError(
            f"delai de {COMMAND_TIMEOUT_SECONDS}s dépasse par {safe_display(executable)}"
        ) from exc
    except OSError as exc:
        raise ConfigError(f"exécution impossible de {safe_display(executable)}: {exc}") from exc


def validate_with_caddy(candidate_path: Path, caddy_bin: Path) -> None:
    """Fait valider le fichier candidat par un binaire Caddy de confiance."""
    result = run_command(
        [caddy_bin, "validate", "--config", candidate_path, "--adapter", "caddyfile"]
    )
    if result.returncode != 0:
        détails = safe_command_output(result.stdout) or "aucun détail fourni"
        raise ConfigError(f"validation Caddy refusée :\n{détails}")


def fsync_directory(directory: Path) -> None:
    """Demande la persistance d'un renommage, sans masquer un succès atomique."""
    try:
        fd = os.open(
            directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        warn(f"fsync impossible sur {safe_display(directory)}: {exc}")


def write_temp_file(
    caddyfile: Path, data: bytes, metadata: FileSnapshot, *, prefix: str
) -> Path:
    """Écrit un fichier temporaire durable dans le répertoire du Caddyfile."""
    fd, temp_name = tempfile.mkstemp(prefix=prefix, dir=caddyfile.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temp_path, metadata.uid, metadata.gid)
        os.chmod(temp_path, metadata.mode & 0o777)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise
    return temp_path


def prepare_backup_dir() -> Path:
    """Crée (si besoin) et contrôle BACKUP_ROOT, réservé à root (0700)."""
    check_secure_directory(BACKUP_ROOT.parent, "le répertoire parent des sauvegardes")
    try:
        os.mkdir(BACKUP_ROOT, 0o700)
    except FileExistsError:
        pass
    except OSError as exc:
        raise ConfigError(f"création impossible de {BACKUP_ROOT}: {exc}") from exc

    try:
        info = os.lstat(BACKUP_ROOT)
    except OSError as exc:
        raise ConfigError(f"contrôle impossible de {BACKUP_ROOT}: {exc}") from exc
    if not stat_module.S_ISDIR(info.st_mode) or info.st_uid != 0:
        raise ConfigError(
            "le répertoire de sauvegarde doit appartenir à root et ne pas être un lien"
        )
    if info.st_mode & (stat_module.S_IWGRP | stat_module.S_IWOTH):
        raise ConfigError(
            "le répertoire de sauvegarde est modifiable par un utilisateur non privilégié"
        )
    os.chmod(BACKUP_ROOT, 0o700)
    return BACKUP_ROOT


def backup_prefix(caddyfile: Path) -> str:
    """Préfixe des sauvegardes : nom du Caddyfile + empreinte de son chemin."""
    safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", caddyfile.name)[:64] or "Caddyfile"
    path_hash = hashlib.sha256(os.fsencode(caddyfile)).hexdigest()[:12]
    return f"{safe_name}-{path_hash}"


def write_backup(backup_path: Path, data: bytes) -> None:
    """Écrit une sauvegarde 0600 sans jamais écraser un fichier existant."""
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        fd = os.open(backup_path, flags, 0o600)
    except OSError as exc:
        raise ConfigError(f"création impossible de la sauvegarde : {exc}") from exc
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except Exception:
        backup_path.unlink(missing_ok=True)
        raise
    fsync_directory(backup_path.parent)


def prune_backups(backup_dir: Path, prefix: str, keep: int) -> None:
    """Ne conserve que les sauvegardes régulières correspondant au Caddyfile."""
    backups: list[Path] = []
    try:
        entries = list(backup_dir.iterdir())
    except OSError as exc:
        warn(f"inventaire impossible des sauvegardes : {exc}")
        return
    for entry in entries:
        if not entry.name.startswith(f"{prefix}.bak."):
            continue
        try:
            info = os.lstat(entry)
        except OSError as exc:
            warn(f"contrôle impossible de {safe_display(entry)}: {exc}")
            continue
        if stat_module.S_ISREG(info.st_mode) and info.st_uid == 0:
            backups.append(entry)
        else:
            warn(f"sauvegarde inattendue ignorée : {safe_display(entry)}")

    for obsolete in sorted(backups)[:-keep]:
        try:
            obsolete.unlink()
        except OSError as exc:
            warn(f"suppression impossible de {safe_display(obsolete)}: {exc}")
    fsync_directory(backup_dir)


def restore_snapshot(
    caddyfile: Path, original: FileSnapshot, expected_candidate_digest: str
) -> None:
    """Restaure l'original seulement si personne n'a modifié le candidat."""
    _content, current = read_caddyfile(caddyfile, require_secure_permissions=True)
    if current.digest != expected_candidate_digest:
        raise ConfigError(
            "le Caddyfile a encore change après son installation ; retour arriere "
            "automatique refusé pour ne pas écraser cette modification"
        )
    rollback_path = write_temp_file(
        caddyfile, original.data, original, prefix=".Caddyfile.rollback."
    )
    try:
        assert_caddyfile_unchanged(caddyfile, current)
        os.replace(rollback_path, caddyfile)
        fsync_directory(caddyfile.parent)
    finally:
        rollback_path.unlink(missing_ok=True)


def caddy_is_active(systemctl_bin: Path) -> bool:
    """Vrai si le service caddy est actif ; ConfigError si l'état est inconnu."""
    result = run_command([systemctl_bin, "is-active", "--quiet", "caddy"])
    if result.returncode == 0:
        return True
    if result.returncode == 3:
        return False
    détails = safe_command_output(result.stdout) or f"code de retour {result.returncode}"
    raise ConfigError(f"état du service caddy impossible à déterminer : {détails}")


def reload_caddy(
    systemctl_bin: Path,
    caddyfile: Path,
    original: FileSnapshot,
    candidate_digest: str,
) -> None:
    """Recharge Caddy ; en cas d'échec, restaure l'ancien Caddyfile, le
    recharge, puis lève ConfigError avec le détail."""
    try:
        result = run_command([systemctl_bin, "reload", "caddy"])
    except ConfigError as exc:
        # Un timeout laisse un resultat indéterminé : Caddy peut avoir reçu la
        # demande avant l'expiration. On restaure donc aussi dans ce cas.
        détails = str(exc)
    else:
        if result.returncode == 0:
            return
        détails = safe_command_output(result.stdout) or "aucun détail fourni"

    try:
        restore_snapshot(caddyfile, original, candidate_digest)
    except (ConfigError, OSError) as exc:
        raise ConfigError(
            f"rechargement de Caddy impossible :\n{détails}\n"
            f"Retour arriere automatique impossible : {exc}"
        ) from exc

    try:
        rollback = run_command([systemctl_bin, "reload", "caddy"])
    except ConfigError as exc:
        rollback_note = (
            "L'ancien Caddyfile a été restauré, mais son rechargement n'a pas "
            f"pu être confirmé : {exc}"
        )
    else:
        rollback_note = (
            "L'ancien Caddyfile a été restaure."
            if rollback.returncode == 0
            else "L'ancien Caddyfile a été restauré, mais son rechargement a aussi échoué."
        )
    raise ConfigError(f"rechargement de Caddy impossible :\n{détails}\n{rollback_note}")


def apply_configuration(
    caddyfile: Path,
    candidate: str,
    original: FileSnapshot,
    *,
    caddy_bin: Path,
    systemctl_bin: Path | None,
    reload_service: bool,
    keep_backups: int,
) -> tuple[Path, str]:
    """Valide, sauvegarde, remplace et recharge de façon transactionnelle."""
    candidate_data = candidate.encode("utf-8")
    if len(candidate_data) > MAX_CADDYFILE_BYTES:
        raise ConfigError(
            "le Caddyfile généré dépasse la taille maximale de "
            f"{MAX_CADDYFILE_BYTES} octets"
        )
    candidate_digest = hashlib.sha256(candidate_data).hexdigest()
    temp_path = write_temp_file(
        caddyfile, candidate_data, original, prefix=".Caddyfile."
    )
    backup_dir: Path | None = None
    prefix: str | None = None
    try:
        validate_with_caddy(temp_path, caddy_bin)

        service_active = False
        if reload_service:
            if systemctl_bin is None:
                raise ConfigError("systemctl n'a pas été initialise")
            service_active = caddy_is_active(systemctl_bin)

        backup_dir = prepare_backup_dir()
        prefix = backup_prefix(caddyfile)
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        backup_path = backup_dir / f"{prefix}.bak.{timestamp}"

        assert_caddyfile_unchanged(caddyfile, original)
        write_backup(backup_path, original.data)
        assert_caddyfile_unchanged(caddyfile, original)

        os.replace(temp_path, caddyfile)
        fsync_directory(caddyfile.parent)

        note = ""
        if reload_service and service_active:
            if systemctl_bin is None:
                raise ConfigError("systemctl n'a pas été initialise")
            reload_caddy(systemctl_bin, caddyfile, original, candidate_digest)
        elif reload_service:
            note = (
                "le service caddy n'est pas actif : rechargement ignoré "
                "(demarre-le avec : systemctl start caddy)"
            )

        return backup_path, note
    finally:
        temp_path.unlink(missing_ok=True)
        # La rétention s'applique aussi après un rollback ou une course
        # détectée, faute de quoi des échecs répétés pourraient remplir /var.
        if backup_dir is not None and prefix is not None:
            prune_backups(backup_dir, prefix, keep_backups)


class FileLock:
    """Verrou exclusif non bloquant, libéré à la sortie du bloc with."""

    def __init__(self, path: Path) -> None:
        """Prépare le verrou sans l'ouvrir."""
        self.path = path
        self._fd: int | None = None

    def __enter__(self) -> "FileLock":
        """Ouvre le fichier de verrou, contrôle sa sûreté et pose un flock exclusif."""
        flags = (
            os.O_CREAT
            | os.O_RDWR
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            self._fd = os.open(self.path, flags, 0o600)
        except OSError as exc:
            raise ConfigError(
                f"création impossible du verrou {safe_display(self.path)}: {exc}"
            ) from exc
        info = os.fstat(self._fd)
        if (
            not stat_module.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_mode & (stat_module.S_IWGRP | stat_module.S_IWOTH)
        ):
            os.close(self._fd)
            self._fd = None
            raise ConfigError("le fichier de verrouillage n'est pas sur")
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self._fd)
            self._fd = None
            raise ConfigError(
                f"une autre instance de {SCRIPT_NAME} est en cours "
                f"({safe_display(self.path)})"
            ) from exc
        return self

    def __exit__(self, *_exc_info: object) -> None:
        """Libère le verrou."""
        if self._fd is not None:
            # Le verrou est libéré par la fermeture du descripteur ; le fichier
            # lui-meme est laisse en place, il ne coûte rien.
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None


# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------


def main() -> int:
    """Point d'entrée : charge le YAML, construit le Caddyfile et l'applique."""
    args = parse_args()
    caddyfile = absolute_path(args.caddyfile)
    yaml_path = absolute_path(args.yaml_file)

    try:
        if not args.dry_run and os.geteuid() != 0:
            raise ConfigError("ce script doit être exécuté avec sudo ou par root")

        # Tous les réglages d'accès vivent désormais dans le YAML. Les anciennes
        # options sont refusées avec un message qui indique leur remplaçant.
        removed: list[str] = []
        if args.allowed_networks is not None:
            removed.append("--allowed-networks -> réglage 'allowed_networks'")
        if args.redirect_url is not None:
            removed.append("--redirect-url -> réglage 'outside_redirect_url'")
        if args.max_body_size is not None:
            removed.append("--max-body-size -> réglage 'max_request_body_size'")
        if args.public:
            removed.append("--public -> clé 'access: public' par site")
        if removed:
            raise ConfigError(
                "option(s) retirée(s) dans la version 2.7.0 ; place ces réglages "
                "dans le bloc 'settings' du YAML (surchargeables par site) : "
                + " ; ".join(removed)
            )

        caddy_bin: Path | None = None
        systemctl_bin: Path | None = None
        if not args.dry_run:
            if not args.no_reload and caddyfile != DEFAULT_CADDYFILE:
                raise ConfigError(
                    "un --caddyfile personnalisé exige --no-reload : le service "
                    "systemd pourrait utiliser un autre fichier"
                )
            caddy_bin = check_trusted_executable(CADDY_BIN, "Caddy")
            if not args.no_reload:
                systemctl_bin = check_trusted_executable(SYSTEMCTL_BIN, "systemctl")

        proxies = load_proxies(
            yaml_path, require_secure_permissions=not args.dry_run
        )

        render_options = {
            "source": yaml_path,
            "explicit_http_redirects": args.explicit_http_redirects,
        }

        # --dry-run ne touche à rien et ne demande donc ni root ni verrou.
        if args.dry_run:
            current, _snapshot = read_caddyfile(
                caddyfile, require_secure_permissions=False
            )
            print(build_candidate(current, proxies, **render_options), end="")
            return 0

        # Le verrou couvre lecture + écriture : sans lui, deux exécutions
        # concurrentes liraient le meme état initial et la seconde écraserait
        # le travail de la première.
        with FileLock(LOCK_PATH):
            current, snapshot = read_caddyfile(
                caddyfile, require_secure_permissions=True
            )
            candidate = build_candidate(current, proxies, **render_options)

            if is_equivalent(candidate, current):
                ok(
                    "Aucune modification nécessaire dans "
                    f"{safe_display(caddyfile)}."
                )
                return 0

            if caddy_bin is None:
                raise ConfigError("Caddy n'a pas été initialise")
            backup_path, note = apply_configuration(
                caddyfile,
                candidate,
                snapshot,
                caddy_bin=caddy_bin,
                systemctl_bin=systemctl_bin,
                reload_service=not args.no_reload,
                keep_backups=args.keep_backups,
            )
    except (ConfigError, OSError, UnicodeError) as exc:
        fail(str(exc))

    action = "mis à jour et validé"
    if not args.no_reload and not note:
        action += " ; Caddy a été rechargé"
    ok(f"{safe_display(caddyfile)} {action}.")
    if note:
        info(note)
    log(f"   Sauvegarde précédente : {safe_display(backup_path)}")
    public_count = sum(1 for proxy in proxies if proxy.is_public)
    host_count = sum(1 for proxy in proxies if proxy.upstream_host)
    log(
        f"   Reverse proxies gérés : {len(proxies)} "
        f"(publics : {public_count}, privés : {len(proxies) - public_count}"
        + (f", Host forcé : {host_count}" if host_count else "")
        + ")"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

