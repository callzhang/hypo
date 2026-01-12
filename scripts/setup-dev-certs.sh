#!/bin/bash
# Setup self-signed certificate for Hypo development
# This prevents repeated accessibility permission prompts on macOS

set -e

CERT_NAME="HypoSelfSign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Checking for existing '$CERT_NAME' certificate...${NC}"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo -e "${GREEN}✅ Certificate '$CERT_NAME' already exists and is valid.${NC}"
    exit 0
fi

echo -e "${YELLOW}Creating self-signed code signing certificate '$CERT_NAME'...${NC}"

# Create config for openssl
cat > hypo_cert.cnf <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_req

[ req_distinguished_name ]
CN = $CERT_NAME

[ v3_req ]
keyUsage           = critical, digitalSignature
extendedKeyUsage   = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# Generate cert
openssl req -x509 -newkey rsa:2048 -keyout hypo_key.pem -out hypo_cert.pem -days 3650 -nodes -config hypo_cert.cnf 2>/dev/null
# Use legacy/compatible encryption for PKCS12 to ensure macOS 'security' tool can import it
openssl pkcs12 -export -in hypo_cert.pem -inkey hypo_key.pem -out hypo_cert.p12 -passout pass:hypo -name "$CERT_NAME" -legacy 2>/dev/null

echo -e "${GREEN}Importing certificate to login keychain...${NC}"
# Import to keychain
# -A: Allow all applications to access this item (prevents some prompts)
# -T /usr/bin/codesign: Explicitly allow codesign to access it
security import hypo_cert.p12 -k "$KEYCHAIN" -P hypo -T /usr/bin/codesign

# Clean up
rm hypo_cert.cnf hypo_key.pem hypo_cert.pem hypo_cert.p12

echo -e "${GREEN}✅ Certificate created and imported.${NC}"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT FINAL STEP:${NC}"
echo "1. The system may still consider this certificate 'untrusted' by default."
echo "2. If code signing fails or apps still prompt:"
echo "   a. Open 'Keychain Access' app"
echo "   b. Search for '$CERT_NAME'"
echo "   c. Double-click it, expand 'Trust'"
echo "   d. Set 'When using this certificate' to 'Always Trust'"
echo ""
