#!/bin/bash
# Crea una volta sola il certificato con cui build_app.sh firma Upgrady.
#
# Con una firma sempre uguale macOS ricorda i permessi (es. Gestione app) anche dopo gli aggiornamenti;
# con la firma ad-hoc cambiano a ogni build. Il certificato è auto-firmato: non serve un account Apple
# e per chi scarica l'app non cambia nulla.
#
# Cosa fa:
#   1. crea chiave e certificato per la firma del codice (validi 20 anni);
#   2. salva una copia di sicurezza protetta da password in ~/Documents (tienila al sicuro, mai nel repository);
#   3. li importa nel portachiavi "login", consentendone l'uso a codesign.
# Non serve segnarlo come attendibile: la firma è valida e macOS riconosce l'app dal certificato.
set -euo pipefail

NAME="${1:-Gionnio Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP="$HOME/Documents/$(echo "$NAME" | tr ' ' '-')-backup.p12"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Il certificato \"$NAME\" esiste già nel portachiavi."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "▸ Creo chiave e certificato \"$NAME\""
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

echo "▸ Scegli una password per la copia di sicurezza (ti servirà per reimportarlo su un altro Mac)"
read -r -s -p "Password: " P12_PASSWORD; echo
read -r -s -p "Ripeti: " P12_CHECK; echo
[ "$P12_PASSWORD" = "$P12_CHECK" ] || { echo "Le password non coincidono."; exit 1; }
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$BACKUP" -passout pass:"$P12_PASSWORD"
chmod 600 "$BACKUP"

echo "▸ Importo nel portachiavi login"
security import "$BACKUP" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null

echo
security find-identity -p codesigning | grep -q "\"$NAME\"" && echo "✓ Pronto: build_app.sh userà \"$NAME\"."
echo "Copia di sicurezza: $BACKUP — spostala in un posto sicuro (es. un gestore di password), non nel repository."
