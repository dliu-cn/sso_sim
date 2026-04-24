#!/bin/bash
# Let's Encrypt certificate acquisition and nginx startup.
# Expects IDP_HOSTNAME to be set in the environment.
# nginx must NOT be running when this script starts (certbot uses standalone mode).
set -euo pipefail

echo "--- [nginx] Requesting Let's Encrypt certificate..."
certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "admin@${IDP_HOSTNAME}" \
    -d "${IDP_HOSTNAME}" \
    --keep-until-expiring

echo "--- [nginx] Configuring nginx..."
cp /opt/shibboleth-config/nginx.conf /etc/nginx/conf.d/shibboleth-idp.conf
sed -i "s|__IDP_HOSTNAME__|${IDP_HOSTNAME}|g" /etc/nginx/conf.d/shibboleth-idp.conf
rm -f /etc/nginx/conf.d/default.conf
nginx -t

echo "--- [nginx] Starting nginx..."
systemctl start nginx

echo "--- [nginx] Setting up cert renewal cron..."
cat > /etc/cron.d/certbot-renew << 'EOF'
0 3 1 */2 * root certbot renew --quiet \
    --pre-hook  "systemctl stop  nginx" \
    --post-hook "systemctl start nginx"
EOF

echo "--- [nginx] Done."
