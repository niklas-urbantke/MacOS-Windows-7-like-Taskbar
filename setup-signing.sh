#!/bin/bash
# Einmalig ausführen: erzeugt eine stabile, selbst-signierte Code-Signatur-Identität.
# Dadurch bleiben erteilte Berechtigungen (Bildschirmaufnahme, Bedienungshilfen) über
# Rebuilds hinweg erhalten – sonst setzt macOS sie bei jedem Neubauen zurück.
set -e
cd "$(dirname "$0")"

IDENTITY="Win7Taskbar Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Vorhandenes (evtl. fehlerhaftes) Zertifikat entfernen, damit ein sauberes entsteht.
security delete-certificate -c "$IDENTITY" "$KEYCHAIN" 2>/dev/null || true

TMP=$(mktemp -d)
echo "▶ Erzeuge Zertifikat (mit korrekter Key Usage)…"
cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Win7Taskbar Self-Signed
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -newkey rsa:2048 -nodes -keyout "$TMP/k.key" -x509 -days 3650 \
    -out "$TMP/c.crt" -config "$TMP/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -out "$TMP/i.p12" -inkey "$TMP/k.key" -in "$TMP/c.crt" -passout pass:w7 -legacy

echo "▶ Importiere in den Schlüsselbund…"
security import "$TMP/i.p12" -k "$KEYCHAIN" -P w7 -T /usr/bin/codesign -A

echo ""
echo ">>> Es erscheint gleich eine Passwort-Abfrage, um das Zertifikat fürs Signieren"
echo "    zu vertrauen. Bitte dein Login-Passwort eingeben. <<<"
echo ""
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/c.crt"

rm -rf "$TMP"

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✔ Gültige Signatur-Identität angelegt. Jetzt ./build.sh ausführen."
else
    echo "⚠ Identität noch nicht als gültig erkannt – bitte Ausgabe prüfen."
fi
