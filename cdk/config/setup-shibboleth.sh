#!/bin/bash
# One-time Shibboleth IdP setup: pull image, generate/restore credentials, configure Jetty.
# Run on first boot, or to rotate credentials.
# Expects: IDP_HOSTNAME, S3_BUCKET in environment (or /etc/shibboleth-env.sh)
set -euo pipefail

[ -z "${S3_BUCKET:-}" ] && source /etc/shibboleth-env.sh

CREDS_DIR=/opt/shibboleth-idp/credentials
METADATA_DIR=/opt/shibboleth-idp/metadata
JETTY_START_D=/opt/shib-jetty-base/start.d-local

echo "--- [setup-shibboleth] Pulling Docker image..."
docker pull unicon/shibboleth-idp:latest

# ── Credentials ──────────────────────────────────────────────────────
mkdir -p "$CREDS_DIR" "$METADATA_DIR"

if aws s3 ls "s3://${S3_BUCKET}/credentials/sealer.jks" &>/dev/null; then
    echo "--- [setup-shibboleth] Restoring credentials from S3..."
    aws s3 sync "s3://${S3_BUCKET}/credentials/" "$CREDS_DIR/"
else
    echo "--- [setup-shibboleth] Generating new credentials..."
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$CREDS_DIR/idp-signing.key" \
        -x509 -days 3650 -out "$CREDS_DIR/idp-signing.crt" \
        -subj "/CN=${IDP_HOSTNAME}" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$CREDS_DIR/idp-encryption.key" \
        -x509 -days 3650 -out "$CREDS_DIR/idp-encryption.crt" \
        -subj "/CN=${IDP_HOSTNAME}" 2>/dev/null

    # keytool is not executable in the image; chmod + run as root inside container
    docker run --rm --user root \
        -v "${CREDS_DIR}:/creds" \
        --entrypoint sh unicon/shibboleth-idp:latest \
        -c 'chmod +x /opt/jre-home/bin/keytool \
            && /opt/jre-home/bin/keytool -genseckey -alias secret -keyalg AES -keysize 128 \
               -storetype JCEKS -keystore /creds/sealer.jks \
               -storepass password -keypass password \
            && echo 1 > /creds/sealer.kver \
            && chmod -R a+rw /creds'

    echo "--- [setup-shibboleth] Uploading credentials to S3..."
    aws s3 sync "$CREDS_DIR/" "s3://${S3_BUCKET}/credentials/"
fi

# ── IdP metadata (HTTPS — nginx terminates TLS) ───────────────────────
if [ ! -f "$METADATA_DIR/idp-metadata.xml" ]; then
    echo "--- [setup-shibboleth] Generating idp-metadata.xml..."
    CERT_DATA=$(sed '/^-----/d' "$CREDS_DIR/idp-signing.crt" | tr -d '\n')
    cat > "$METADATA_DIR/idp-metadata.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
    xmlns:ds="http://www.w3.org/2000/09/xmldsig#"
    entityID="https://${IDP_HOSTNAME}/idp/shibboleth">
  <md:IDPSSODescriptor
      protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol urn:oasis:names:tc:SAML:1.1:protocol urn:mace:shibboleth:1.0">
    <md:KeyDescriptor use="signing">
      <ds:KeyInfo><ds:X509Data><ds:X509Certificate>${CERT_DATA}</ds:X509Certificate></ds:X509Data></ds:KeyInfo>
    </md:KeyDescriptor>
    <md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:transient</md:NameIDFormat>
    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
        Location="https://${IDP_HOSTNAME}/idp/profile/SAML2/POST/SSO"/>
    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
        Location="https://${IDP_HOSTNAME}/idp/profile/SAML2/Redirect/SSO"/>
    <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
        Location="https://${IDP_HOSTNAME}/idp/profile/SAML2/Redirect/SLO"/>
    <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
        Location="https://${IDP_HOSTNAME}/idp/profile/SAML2/POST/SLO"/>
  </md:IDPSSODescriptor>
</md:EntityDescriptor>
EOF
fi

# ── Jetty start.d: remove SSL connectors (nginx handles TLS) ─────────
echo "--- [setup-shibboleth] Configuring Jetty start.d..."
mkdir -p "$JETTY_START_D"
docker run --rm unicon/shibboleth-idp:latest \
    tar -C /opt/shib-jetty-base/start.d -c . \
    | tar -C "$JETTY_START_D" -x
chmod -R a+rwX "$JETTY_START_D"
rm -f "$JETTY_START_D/ssl.ini"
rm -f "$JETTY_START_D/backchannel.ini"
rm -f "$JETTY_START_D/https.ini"
# Trust X-Forwarded-Proto: https from nginx so Shibboleth sees HTTPS scheme.
# jetty-http-forwarded.xml ships with Jetty 9.3 and adds ForwardedRequestCustomizer.
echo 'etc/jetty-http-forwarded.xml' > "$JETTY_START_D/forwarded.ini"

echo "--- [setup-shibboleth] Done."
