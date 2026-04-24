#!/bin/bash
# EC2 startup script for Shibboleth test IdP.
# Runs as root via EC2 user data. Environment variables are injected by CDK.
# Logs: /var/log/shibboleth-startup.log
set -euo pipefail

echo "=== Shibboleth IdP startup: $(date) ==="
echo "IDP_HOSTNAME=$IDP_HOSTNAME"
echo "S3_BUCKET=$S3_BUCKET"
echo "COGNITO_POOL_ID=$COGNITO_POOL_ID"

# ── 1. Install dependencies ──────────────────────────────────────────
echo "--- Installing packages..."
dnf update -y
dnf install -y docker nginx certbot
systemctl enable --now docker
systemctl enable nginx

# ── 2. Persist env vars for later re-runs ───────────────────────────
echo "--- Writing /etc/shibboleth-env.sh..."
cat > /etc/shibboleth-env.sh << EOF
export IDP_HOSTNAME=${IDP_HOSTNAME}
export S3_BUCKET=${S3_BUCKET}
export COGNITO_POOL_ID=${COGNITO_POOL_ID}
export COGNITO_REGION=${COGNITO_REGION}
export COGNITO_SP_ENTITY_ID=${COGNITO_SP_ENTITY_ID}
export COGNITO_SP_ACS_URL=${COGNITO_SP_ACS_URL}
EOF

# ── 3. Download all scripts and config from S3 ───────────────────────
echo "--- Downloading config from S3..."
mkdir -p /opt/shibboleth-config
aws s3 sync "s3://${S3_BUCKET}/config/" /opt/shibboleth-config/
chmod +x /opt/shibboleth-config/*.sh
find /opt/shibboleth-config/authn -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

# ── 4. One-time setup: credentials + Jetty start.d ───────────────────
bash /opt/shibboleth-config/setup-shibboleth.sh

# ── 5. Build conf dir + start container ─────────────────────────────
bash /opt/shibboleth-config/start-shibboleth.sh

# ── 6. Start nginx + Let's Encrypt ───────────────────────────────────
bash /opt/shibboleth-config/startup-nginx.sh

echo "=== Startup complete: $(date) ==="
echo ""
echo "IdP metadata URL : https://${IDP_HOSTNAME}/idp/shibboleth"
echo "IdP SSO URL      : https://${IDP_HOSTNAME}/idp/profile/SAML2/Redirect/SSO"
echo "SP Entity ID     : ${COGNITO_SP_ENTITY_ID}"
echo "SP ACS URL       : ${COGNITO_SP_ACS_URL}"
echo ""
echo "Connect via SSM  : aws ssm start-session --target <INSTANCE_ID>"
echo "Check container  : docker logs shibboleth-idp | tail -20"
echo "Apply config chg : source /etc/shibboleth-env.sh && bash /opt/shibboleth-config/start-shibboleth.sh"
