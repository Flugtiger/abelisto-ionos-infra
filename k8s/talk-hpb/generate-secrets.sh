#!/usr/bin/env sh
# Erzeugt secrets.env mit zufaelligen Secrets (nur wenn noch nicht vorhanden).
set -eu
cd "$(dirname "$0")"
if [ -f secrets.env ]; then echo "secrets.env existiert bereits – nichts geaendert."; exit 0; fi
gen() { openssl rand -hex 32; }
cat > secrets.env <<EOT
TURN_SECRET=$(gen)
SIGNALING_SECRET=$(gen)
INTERNAL_SECRET=$(gen)
EOT
chmod 600 secrets.env
echo "secrets.env erzeugt. TURN_SECRET und SIGNALING_SECRET werden in Nextcloud eingetragen."
