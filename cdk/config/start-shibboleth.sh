#!/bin/bash
# Build Shibboleth conf dir and (re)start the container.
# Re-run after any config change: add/modify users, add Cognito IdP, etc.
#
# Usage (from EC2):
#   bash /opt/shibboleth-config/start-shibboleth.sh
#
# Expects: IDP_HOSTNAME, S3_BUCKET, COGNITO_SP_ENTITY_ID, COGNITO_SP_ACS_URL
# (sourced from /etc/shibboleth-env.sh if not already set)
set -euo pipefail

[ -z "${S3_BUCKET:-}" ] && source /etc/shibboleth-env.sh

CONF_DIR=/opt/shibboleth-idp/conf
STAGING_DIR=/opt/shibboleth-config

echo "--- [start-shibboleth] Syncing config from S3..."
mkdir -p "$STAGING_DIR"
aws s3 sync "s3://${S3_BUCKET}/config/" "$STAGING_DIR/"

echo "--- [start-shibboleth] Extracting Docker default conf..."
rm -rf "$CONF_DIR"
mkdir -p "$CONF_DIR/authn"
# tar-pipe: avoids docker cp root-ownership and path-nesting issues
docker run --rm unicon/shibboleth-idp:latest \
    tar -C /opt/shibboleth-idp/conf -c . \
    | tar -C "$CONF_DIR" -x
chmod -R a+rwX "$CONF_DIR"

echo "--- [start-shibboleth] Overlaying custom config..."
cp "$STAGING_DIR/idp.properties"          "$CONF_DIR/idp.properties"
cp "$STAGING_DIR/attribute-filter.xml"    "$CONF_DIR/attribute-filter.xml"
cp "$STAGING_DIR/attribute-resolver.xml"  "$CONF_DIR/attribute-resolver.xml"
cp "$STAGING_DIR/metadata-providers.xml"  "$CONF_DIR/metadata-providers.xml"
cp "$STAGING_DIR/cognito-sp-metadata.xml" "$CONF_DIR/cognito-sp-metadata.xml"
cp "$STAGING_DIR/users.htpasswd"          "$CONF_DIR/users.htpasswd"
cp "$STAGING_DIR/relying-party.xml"                        "$CONF_DIR/relying-party.xml"
cp "$STAGING_DIR/saml-nameid.xml"                          "$CONF_DIR/saml-nameid.xml"
cp "$STAGING_DIR/authn/password-authn-config.xml"         "$CONF_DIR/authn/password-authn-config.xml"
cp "$STAGING_DIR/authn/jaas.config"                        "$CONF_DIR/authn/jaas.config"
cp "$STAGING_DIR/authn/users.properties"                   "$CONF_DIR/authn/users.properties"

echo "--- [start-shibboleth] Substituting placeholders..."
sed -i "s|__IDP_HOSTNAME__|${IDP_HOSTNAME}|g"                  "$CONF_DIR/idp.properties"
sed -i "s|__COGNITO_SP_ENTITY_ID__|${COGNITO_SP_ENTITY_ID}|g"  "$CONF_DIR/cognito-sp-metadata.xml"
sed -i "s|__COGNITO_SP_ACS_URL__|${COGNITO_SP_ACS_URL}|g"      "$CONF_DIR/cognito-sp-metadata.xml"
sed -i "s|__COGNITO_SP_ENTITY_ID__|${COGNITO_SP_ENTITY_ID}|g"  "$CONF_DIR/attribute-filter.xml"

echo "--- [start-shibboleth] (Re)starting container..."
# Ensure Jetty reads X-Forwarded-Proto: https from nginx.
echo 'etc/jetty-http-forwarded.xml' > /opt/shib-jetty-base/start.d-local/forwarded.ini
# Enable Jetty JAAS module (makes PropertyFileLoginModule available) and point JVM at our JAAS config.
printf -- '--module=jaas\n-Djava.security.auth.login.config=/opt/shibboleth-idp/conf/authn/jaas.config\n' \
    > /opt/shib-jetty-base/start.d-local/jaas.ini
docker rm -f shibboleth-idp 2>/dev/null || true
mkdir -p /opt/shibboleth-idp/logs

docker run -d \
    --name shibboleth-idp \
    --restart unless-stopped \
    -p 8080:8080 \
    -e JETTY_HTTP_PORT=8080 \
    -v "${CONF_DIR}:/opt/shibboleth-idp/conf" \
    -v "/opt/shibboleth-idp/credentials:/opt/shibboleth-idp/credentials" \
    -v "/opt/shibboleth-idp/metadata:/opt/shibboleth-idp/metadata" \
    -v "/opt/shib-jetty-base/start.d-local:/opt/shib-jetty-base/start.d" \
    -v "/opt/shibboleth-idp/logs:/opt/shibboleth-idp/logs" \
    unicon/shibboleth-idp:latest

echo "--- [start-shibboleth] Done. Container starting..."
echo "--- [start-shibboleth] Monitor with: docker logs -f shibboleth-idp"
