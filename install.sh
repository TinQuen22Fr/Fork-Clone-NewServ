#!/usr/bin/env bash
#
# Claude Unchained Forge — installation (modele COMPARTIMENTE, serveur OVH KS-LE-3).
#
#   SOURCE   (clone git, `git pull` MANUEL)  : /opt/forge-newserv   (ce depot)
#   RUNTIME  (execution, servi par Nginx)    : /var/www/forge       (SANS .git)
#   CONFIG   (.env, chmod 600)               : /etc/forge/backend.env + /etc/forge/frontend.env
#   WORKSPACE (sandboxes des previews)       : /home/ubuntu/vibe-coding/workspace
#
# Le code est COPIE (rsync) de SOURCE vers RUNTIME : AUCUN script du depot ne
# fait de `git pull`. Tu mets a jour le clone toi-meme, puis tu relances :
#     cd /opt/forge-newserv && git pull --ff-only
#     sudo bash /opt/forge-newserv/install.sh      # premiere install
#     sudo bash /opt/forge-newserv/upgrade.sh      # mises a jour suivantes
#
# Ne touche JAMAIS a Nginx (a faire a la main — vhost dans /etc/nginx/conf.d/).
#
set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
RUNTIME_DIR="${RUNTIME_DIR:-/var/www/forge}"
APP_DIR="$RUNTIME_DIR"
BACKEND_DIR="$APP_DIR/backend"
FRONTEND_DIR="$APP_DIR/frontend"

ENV_DIR="${ENV_DIR:-/etc/forge}"
ENV_FILE="${ENV_FILE:-$ENV_DIR/backend.env}"
FRONTEND_ENV_FILE="${FRONTEND_ENV_FILE:-$ENV_DIR/frontend.env}"

SERVICE_NAME="forge-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

SERVICE_USER="${SERVICE_USER:-ubuntu}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/home/ubuntu/vibe-coding/workspace}"
LITELLM_VENV="${LITELLM_VENV:-/var/www/forge/litellm-venv}"
LITELLM_SERVICE="${LITELLM_SERVICE:-litellm}"
LITELLM_SERVICE_FILE="/etc/systemd/system/${LITELLM_SERVICE}.service"

EXPECTED_REMOTE="TinQuen22Fr/Fork-Clone-NewServ"
EXPECTED_BRANCH="vibecoding-newserv"

c_info()  { printf '\033[36m[i]\033[0m %s\n' "$1"; }
c_ok()    { printf '\033[32m[OK]\033[0m %s\n' "$1"; }
c_warn()  { printf '\033[33m[!]\033[0m %s\n' "$1"; }
c_error() { printf '\033[31m[X]\033[0m %s\n' "$1" >&2; }
die()     { c_error "$1"; exit 1; }

RSYNC_EXCLUDES=(
    --exclude='.git/'
    --exclude='backend/venv/'
    --exclude='litellm-venv/'
    --exclude='frontend/node_modules/'
    --exclude='frontend/build/'
    --exclude='.playwright/'
    --exclude='backend/static/screenshots/'
    --exclude='backend/.env'
    --exclude='*.bak-*'
    --exclude='.upgrade-*.sha'
    --exclude='.forge-preview-db-clone'
)

# ---------------------------------------------------------------------------
# 0. Verifications prealables
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "a lancer en root : sudo bash $SOURCE_DIR/install.sh"
for b in python3 npm systemctl rsync; do
    command -v "$b" >/dev/null || die "$b introuvable."
done
[ -f "$SOURCE_DIR/backend/server.py" ] || die "$SOURCE_DIR ne ressemble pas au clone de la Forge."

c_info "SOURCE  (clone)   : $SOURCE_DIR"
c_info "RUNTIME (prod)    : $RUNTIME_DIR"
c_info "CONFIG            : $ENV_DIR"
c_info "WORKSPACE         : $WORKSPACE_DIR"

# Controle origin/branche du clone (non bloquant).
if git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    CUR_REMOTE="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
    CUR_BRANCH="$(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    case "$CUR_REMOTE" in
        *"$EXPECTED_REMOTE"*) c_ok "origin = $EXPECTED_REMOTE" ;;
        *) c_warn "origin inattendu : ${CUR_REMOTE:-<aucun>} (attendu *$EXPECTED_REMOTE*)" ;;
    esac
    [ "$CUR_BRANCH" = "$EXPECTED_BRANCH" ] \
        && c_ok "branche = $EXPECTED_BRANCH" \
        || c_warn "branche courante '$CUR_BRANCH' (attendu '$EXPECTED_BRANCH')"
fi

# ---------------------------------------------------------------------------
# 1. Configuration /etc/forge (ne JAMAIS ecraser un .env existant)
# ---------------------------------------------------------------------------
mkdir -p "$ENV_DIR"
chmod 750 "$ENV_DIR"
if [ ! -f "$ENV_FILE" ]; then
    install -m 600 "$SOURCE_DIR/backend/env.example" "$ENV_FILE"
    c_warn "$ENV_FILE cree depuis env.example."
    c_warn "Edite-le (ou recupere le .env de la Dedibox — voir PROCEDURE_DEPLOIEMENT_OVH.md) :"
    c_warn "  nano $ENV_FILE"
    c_warn "Renseigne au minimum JWT_SECRET, MONGO_URL, FRONTEND_URL, puis relance ce script."
    exit 0
else
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    c_ok "$ENV_FILE present (non modifie)."
fi

# ---------------------------------------------------------------------------
# 2. Synchronisation du code  SOURCE (clone) -> RUNTIME (execution)
# ---------------------------------------------------------------------------
c_info "Copie du code $SOURCE_DIR -> $RUNTIME_DIR (sans .git)..."
mkdir -p "$RUNTIME_DIR"
rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$SOURCE_DIR"/ "$RUNTIME_DIR"/
c_ok "code copie dans $RUNTIME_DIR."

# ---------------------------------------------------------------------------
# 3. Backend — environnement virtuel + dependances (dans le RUNTIME)
# ---------------------------------------------------------------------------
c_info "Backend : environnement virtuel..."
if [ ! -d "$BACKEND_DIR/venv" ]; then
    python3 -m venv "$BACKEND_DIR/venv"
    c_ok "venv cree."
else
    c_ok "venv deja present."
fi
"$BACKEND_DIR/venv/bin/pip" install --upgrade pip --quiet
"$BACKEND_DIR/venv/bin/pip" install -r "$BACKEND_DIR/requirements.txt" --quiet
c_ok "Dependances Python installees."

# ---------------------------------------------------------------------------
# 4. Frontend — .env (copie depuis /etc/forge au build), deps + build
# ---------------------------------------------------------------------------
if [ -f "$FRONTEND_ENV_FILE" ]; then
    install -m 0644 "$FRONTEND_ENV_FILE" "$FRONTEND_DIR/.env"
    c_ok "frontend/.env copie depuis $FRONTEND_ENV_FILE."
else
    c_info "Pas de $FRONTEND_ENV_FILE — le frontend utilisera /api (meme origine)."
fi
c_info "Frontend : installation des dependances (npm)..."
(cd "$FRONTEND_DIR" && npm install)
c_info "Frontend : build de production..."
(cd "$FRONTEND_DIR" && npm run build)
[ -f "$FRONTEND_DIR/build/index.html" ] || die "build frontend echoue (build/index.html absent)."
c_ok "Build genere dans $FRONTEND_DIR/build/."

# ---------------------------------------------------------------------------
# 5. Service systemd — jamais d'ecrasement d'une unite existante
# ---------------------------------------------------------------------------
NEW_SERVICE="$APP_DIR/deploy/forge-backend.service"
if [ ! -f "$SERVICE_FILE" ]; then
    cp "$NEW_SERVICE" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    c_ok "Service installe et active (EnvironmentFile=$ENV_FILE)."
elif ! diff -q "$NEW_SERVICE" "$SERVICE_FILE" >/dev/null 2>&1; then
    c_ok "Service systemd existant conserve intact (durcissement preserve)."
    c_warn "Il differe du gabarit. Pour comparer sans rien changer :"
    c_info "  diff -u $SERVICE_FILE $NEW_SERVICE"
else
    c_ok "Service systemd deja identique au gabarit."
fi

# Chemins inscriptibles (ReadWritePaths) : complete l'unite SANS rien supprimer.
if [ -f "$SERVICE_FILE" ]; then
    WORKSPACE_DIR="$WORKSPACE_DIR" bash "$APP_DIR/deploy/ensure-rwpaths.sh" "$SERVICE_FILE" "$APP_DIR" \
        && systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
# 6. Proxy LiteLLM — venv dedie + service systemd
# ---------------------------------------------------------------------------
c_info "LiteLLM : environnement virtuel dedie..."
if [ ! -d "$LITELLM_VENV" ]; then
    python3 -m venv "$LITELLM_VENV"
    c_ok "venv LiteLLM cree ($LITELLM_VENV)."
else
    c_ok "venv LiteLLM deja present."
fi
"$LITELLM_VENV/bin/pip" install --upgrade pip --quiet
"$LITELLM_VENV/bin/pip" install 'litellm[proxy]' --quiet
c_ok "litellm[proxy] installe dans $LITELLM_VENV."

if [ ! -f "$LITELLM_SERVICE_FILE" ]; then
    c_warn "Aucun service litellm — creation du gabarit."
    tee "$LITELLM_SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=LiteLLM proxy (passerelle providers pour la Forge)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$RUNTIME_DIR
Environment="PATH=$LITELLM_VENV/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$LITELLM_VENV/bin/litellm --host 127.0.0.1 --port 4000 --config $APP_DIR/litellm_config.yaml

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$LITELLM_SERVICE" >/dev/null 2>&1 || true
    c_ok "Service litellm cree, recharge et active."
else
    c_ok "Service litellm existant conserve intact."
fi

# ---------------------------------------------------------------------------
# 7. Chemins inscriptibles reels (workspace hors app, .playwright, screenshots)
# ---------------------------------------------------------------------------
mkdir -p "$WORKSPACE_DIR" "$APP_DIR/.playwright" "$APP_DIR/backend/static/screenshots"
chown -R "$SERVICE_USER":"$SERVICE_USER" \
    "$WORKSPACE_DIR" "$APP_DIR/.playwright" "$APP_DIR/backend/static/screenshots" 2>/dev/null \
    || c_warn "chown impossible (utilisateur $SERVICE_USER inconnu ?)"
c_ok "Chemins inscriptibles prets (workspace, .playwright, screenshots)."

# ---------------------------------------------------------------------------
# 8. Redemarrage du backend + verification /api/health
# ---------------------------------------------------------------------------
systemctl restart "$SERVICE_NAME"
systemctl --no-pager status "$SERVICE_NAME" | head -5 || true

PORT="$(grep -m1 -oE '^PORT=[0-9]+' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)"
CODE=000
for _ in $(seq 1 10); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -X GET \
        "http://127.0.0.1:${PORT:-8001}/api/health" || echo 000)"
    [ "$CODE" = "200" ] && break
    sleep 1
done
if [ "$CODE" = "200" ]; then
    c_ok "Backend redemarre — /api/health repond 200."
else
    c_warn "Backend redemarre mais /api/health repond $CODE."
    c_info "  journalctl -u $SERVICE_NAME -n 50 --no-pager"
fi

# ---------------------------------------------------------------------------
# 9. Rappel Nginx (jamais automatise ici)
# ---------------------------------------------------------------------------
echo ""
c_info "Nginx n'est PAS touche par ce script (binaire /usr/sbin/nginx, unite nginx.service)."
c_info "Les vhosts vivent dans /etc/nginx/conf.d/ (pas de sites-available/enabled)."
c_info "Depose/compare le vhost puis recharge, seulement si le diff est voulu :"
c_info "  diff deploy/nginx-forge.conf /etc/nginx/conf.d/forge.conf"
c_info "  sudo nginx -t && sudo systemctl reload nginx"
echo ""
c_ok "Termine."
