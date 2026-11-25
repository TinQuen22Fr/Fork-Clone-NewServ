# Procédure de déploiement — Forge V2 sur serveur OVH KS-LE-3 (`ns3062706`)

> Modèle **compartimenté** : le clone Git et le runtime de prod sont séparés.
> Tu fais les `git pull` **à la main** dans le clone ; aucun script n'y touche.
>
> ⚠️ La prod actuelle sur la Dedibox (`forge.quentin-astro.fr`) reste **intacte**.
> Toute la recette se fait sur `forge-newserv.quentin-astro.fr`.
> Le `.md` de migration généré par l'ancienne instance est **obsolète** : à ignorer.

---

## 1. Cartographie des répertoires

| Rôle | Chemin | Contenu | `.git` ? |
|---|---|---|---|
| **SOURCE** (clone Git, pull manuel) | `/opt/forge-newserv` | dépôt `Fork-Clone-NewServ`, branche `vibecoding-newserv` | **oui** |
| **RUNTIME** (exécution, servi par Nginx) | `/var/www/forge` | copie rsync du code + venv + `frontend/build` | **non** |
| **CONFIG** (chmod 600) | `/etc/forge/backend.env`, `/etc/forge/frontend.env` | variables d'env (backend via systemd, frontend au build) | — |
| **WORKSPACE** (sandboxes previews) | `/home/ubuntu/vibe-coding/workspace` | projets des previews (`ubuntu:ubuntu`) | — |
| État previews | `/var/lib/forge-preview` | état runtime des previews | — |

Flux de déploiement : `git pull` (manuel, dans `/opt`) → `install.sh`/`upgrade.sh` → **rsync** `/opt` → `/var/www/forge` → venv/pip + build + restart systemd.

---

## 2. Pré-requis serveur (DÉJÀ installés — NE PAS réinstaller via `apt`)

- Utilisateur unique **`ubuntu`** (clé SSH only, `sudo` NOPASSWD natif).
- **Nginx** compilé source : binaire `/usr/sbin/nginx`, vhosts dans **`/etc/nginx/conf.d/`**, logs `/var/log/nginx`, unité `nginx.service`.
- **Node.js** (source), **MongoDB 9.0.8** (`mongod.service`), **Docker**, **Certbot** (`/usr/local/bin/certbot` + `certbot-nginx`).
- **mongodb-database-tools** (`mongodump`/`mongorestore` 100.20.1).
- `rsync`, `build-essential`, `python3-venv`, `python3-dev`, Python 3.14.

---

## 3. Étape 1 — Clone du dépôt dans `/opt/forge-newserv`

```bash
sudo mkdir -p /opt/forge-newserv
sudo chown ubuntu:ubuntu /opt/forge-newserv
git clone --branch vibecoding-newserv \
  https://github.com/TinQuen22Fr/Fork-Clone-NewServ.git /opt/forge-newserv
```

> Mises à jour ultérieures = **toi**, à la main :
> `cd /opt/forge-newserv && git pull --ff-only`

---

## 4. Étape 2 — Récupérer la config + les données depuis la Dedibox

Dedibox : `51.158.154.131`, port SSH `65530`, **clé publique uniquement**.
Install actuelle probable : `/var/www/forge` (à confirmer sur place).
Bases à migrer : **`forge`** (obligatoire) et **`forge_preview`** (optionnelle — voir note).

### 4.1 Récupérer le `.env` réel

```bash
# Depuis ton poste (adapte l'alias SSH si tu en as un) :
scp -P 65530 ubuntu@51.158.154.131:/var/www/forge/backend/.env ./backend.env.dedibox
```

### 4.2 Vérifier l'auth MongoDB de la Dedibox

```bash
ssh -p 65530 ubuntu@51.158.154.131 \
  'grep -E "^MONGO_URL=" /var/www/forge/backend/.env; grep -A3 security /etc/mongod.conf 2>/dev/null'
```
- Si `MONGO_URL=mongodb://localhost:27017` (sans user) → pas d'auth.
- Si `mongodb://user:pass@...` → auth ; réutilise la même URI dans les `mongodump` ci-dessous.

### 4.3 Dumps MongoDB (sur la Dedibox)

```bash
ssh -p 65530 ubuntu@51.158.154.131 '
  mongodump --uri="mongodb://localhost:27017" --db=forge         --archive=/tmp/forge.gz         --gzip &&
  mongodump --uri="mongodb://localhost:27017" --db=forge_preview --archive=/tmp/forge_preview.gz --gzip
'
```

### 4.4 Rapatrier les archives (scp — parfaitement adapté ici)

```bash
# Dedibox -> poste -> OVH (le plus sûr avec des clés par poste) :
scp -P 65530 ubuntu@51.158.154.131:/tmp/forge.gz          ./ 
scp -P 65530 ubuntu@51.158.154.131:/tmp/forge_preview.gz  ./ 
scp -P <PORT_OVH> ./forge.gz ./forge_preview.gz  ubuntu@<OVH>:/tmp/
```
> Variante directe Dedibox→OVH sans passer par le poste : `scp -3 -P 65530 ...` (nécessite que ta clé soit chargée dans l'agent SSH).

---

## 5. Étape 3 — Déposer la config dans `/etc/forge`

```bash
sudo mkdir -p /etc/forge && sudo chmod 750 /etc/forge
sudo cp ~/backend.env.dedibox /etc/forge/backend.env
sudo chmod 600 /etc/forge/backend.env
sudo nano /etc/forge/backend.env
```

**Adaptations OBLIGATOIRES dans `/etc/forge/backend.env`** (par rapport au `.env` Dedibox) :

| Clé | Valeur pour le nouveau serveur |
|---|---|
| `FRONTEND_URL` | `https://forge-newserv.quentin-astro.fr` |
| `WORKSPACE_ROOT` | `/home/ubuntu/vibe-coding/workspace` |
| `WORKSPACE_DIR` | `/var/www/forge` |
| `PLAYWRIGHT_BROWSERS_PATH` | `/var/www/forge/.playwright` |
| `MONGO_URL` / `DB_NAME` | MongoDB OVH (`mongodb://localhost:27017` / `forge`) |
| `PREVIEW_MAP_REFRESH_CMD` | `sudo /usr/bin/bash /var/www/forge/deploy/setup-preview-domain.sh --map-only` |

> `frontend.env` est **optionnel** : sans lui, le frontend tape `/api` sur la même origine (Nginx proxy). Si besoin : `sudo cp … /etc/forge/frontend.env && sudo chmod 600 /etc/forge/frontend.env`.

---

## 6. Étape 4 — Première installation

```bash
cd /opt/forge-newserv
sudo bash install.sh
```
- Si `/etc/forge/backend.env` existe déjà (étape 5 faite) → le script enchaîne directement : rsync `/opt` → `/var/www/forge`, venv + `pip`, build frontend, unité systemd (`EnvironmentFile=/etc/forge/backend.env`), venv LiteLLM, `workspace`/`.playwright`/`screenshots`, restart + `GET /api/health`.
- `install.sh` **ne touche jamais** à Nginx.

---

## 7. Étape 5 — Restaurer les bases MongoDB sur OVH

```bash
# Base de prod (obligatoire) :
mongorestore --uri="mongodb://localhost:27017" --archive=/tmp/forge.gz --gzip --drop \
  --nsFrom="forge.*" --nsTo="forge.*"

# Base preview (optionnelle — voir note) :
mongorestore --uri="mongodb://localhost:27017" --archive=/tmp/forge_preview.gz --gzip --drop \
  --nsFrom="forge_preview.*" --nsTo="forge_preview.*"
```
> **Note** : `upgrade.sh` **régénère** `forge_preview` à partir de `forge` à chaque exécution (section « Clonage BDD preview »). Restaurer `forge_preview` n'est donc utile que pour l'état initial avant le premier `upgrade.sh`.

Redémarre pour prendre en compte les données :
```bash
sudo systemctl restart forge-backend
```

---

## 8. Étape 6 — Vhost Nginx (`conf.d`) + certificat

Crée `/etc/nginx/conf.d/forge.conf` (domaine de recette `forge-newserv.quentin-astro.fr`) :

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name forge-newserv.quentin-astro.fr;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name forge-newserv.quentin-astro.fr;

    ssl_certificate     /etc/letsencrypt/live/forge-newserv.quentin-astro.fr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/forge-newserv.quentin-astro.fr/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    client_max_body_size 12M;

    access_log /var/log/nginx/forge.access.log;
    error_log  /var/log/nginx/forge.error.log;

    location /api/ {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    root /var/www/forge/frontend/build;
    index index.html;
    location /assets/ { expires 1y; add_header Cache-Control "public, immutable"; }
    location / { try_files $uri $uri/ /index.html; }
}
```

> Pointe d'abord `forge-newserv.quentin-astro.fr` (A/AAAA chez IONOS) vers l'IP OVH, puis :

```bash
sudo /usr/local/bin/certbot --nginx -d forge-newserv.quentin-astro.fr
sudo nginx -t && sudo systemctl reload nginx
```

---

## 9. Vérification

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/api/health   # 200 attendu
journalctl -u forge-backend -n 50 --no-pager
# puis dans le navigateur : https://forge-newserv.quentin-astro.fr
```

---

## 10. Mises à jour ultérieures (après le premier déploiement)

```bash
cd /opt/forge-newserv && git pull --ff-only     # TOI, manuellement
sudo bash /opt/forge-newserv/upgrade.sh          # rsync + deps + build + restart
# options : --no-sync (runtime déjà à jour), --backend-only, --frontend-only
```

---

## 11. Notes / points d'attention

- **Scripts Python manuels** (`backend/reset_password.py`, etc.) : en modèle compartimenté, ils ne trouvent pas de `.env` dans le runtime. Charge la config avant :
  `set -a && . /etc/forge/backend.env && set +a && /var/www/forge/backend/venv/bin/python backend/reset_password.py`
- **Previews** : wildcard DNS `*.preview.quentin-astro.fr` et map Nginx gérés plus tard, à la main.
- **Partie Docker** (`deploy/docker/`) : hors périmètre pour l'instant, sera réécrite.
- **Bascule prod** : quand la recette est validée, repointer `forge.quentin-astro.fr` (A/AAAA chez IONOS) vers l'IP OVH et ajuster le `server_name` Nginx. Rien à faire côté OVH DNS.
