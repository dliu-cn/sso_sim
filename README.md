# SSO Simulator — Shibboleth Test IdP

A Shibboleth Identity Provider running on AWS for testing the TrialPro SSO feature. Simulates a university SSO (e.g. UNC Chapel Hill) that uses SAML 2.0.

---

## Architecture

```
Browser / Cognito
       │
       ▼ HTTPS 443
  nginx (Let's Encrypt TLS)
       │
       ▼ HTTP 8080
  Shibboleth IdP (Docker)
  unicon/shibboleth-idp
```

- **EC2 t3.small** — Amazon Linux 2023, us-east-1
- **nginx** — TLS termination with free Let's Encrypt certificate
- **Shibboleth IdP** — SAML 2.0 identity provider in Docker
- **Elastic IP + Route 53** — stable public DNS record
- **S3 bucket** — stores Shibboleth config files

**Cost:** ~$17/month always-on. Stop the EC2 instance when not testing → ~$2/month (storage + DNS only).

---

## Prerequisites

- AWS CLI configured for account `623586450996`
- Python 3.9+
- Node.js + CDK CLI:
  ```bash
  npm install -g aws-cdk
  ```
- SSM Session Manager plugin (required to connect to the EC2 without SSH):

  **Linux (Debian/Ubuntu):**
  ```bash
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
  sudo dpkg -i /tmp/session-manager-plugin.deb
  ```
  **Linux (RHEL/Amazon Linux):**
  ```bash
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o /tmp/session-manager-plugin.rpm
  sudo rpm -i /tmp/session-manager-plugin.rpm
  ```
  **Mac:**
  ```bash
  brew install --cask session-manager-plugin
  ```
- A domain with its hosted zone in Route 53 (e.g. `trialpro.ai`)

---

## Setup

### 1. Configure `cdk/cdk.json`

```bash
cp cdk/cdk.json.example cdk/cdk.json
```

Fill in your values:

```json
"account": "123456789012",
"vpc_id": "vpc-XXXXXXXXXXXXXXXXX",
"domain_name": "yourdomain.com",
"cognito_user_pool_id": "us-east-1_XXXXXXXXX",
"cognito_hosted_domain": "yourapp.auth.us-east-1.amazoncognito.com"
```

The IdP will be deployed at `https://{idp_subdomain}.{domain_name}` (default subdomain: `test-idp`).

### 2. Add test users

Edit `cdk/config/users.htpasswd`. Usernames must be email addresses that match UserInfo records in the TrialPro backend DB.

```bash
# Add a user (prompts for password)
htpasswd -B cdk/config/users.htpasswd user@example.com

# Create a new file with first user
htpasswd -cB cdk/config/users.htpasswd user@example.com
```

Pre-generated entries use password `TestPass1!` — replace them with real test user emails.

### 3. Install dependencies and deploy

```bash
# Install CDK CLI (once, globally)
npm install -g aws-cdk

cd cdk
virtualenv venv
. venv/bin/activate
pip install -r requirements.txt

# First time only — sets up CDK bootstrap resources in the AWS account
cdk bootstrap aws://623586450996/us-east-1

cdk deploy
```

Deployment takes ~5 minutes. EC2 startup (Docker pull + Let's Encrypt cert) takes an additional ~3 minutes after the stack is created.

---

## Stack Outputs

After `cdk deploy` completes, the following values are printed:

| Output | Description |
|---|---|
| `IdpMetadataUrl` | Paste into Cognito console when registering this IdP |
| `IdpSsoUrl` | IdP SSO endpoint |
| `SpEntityId` | SP Entity ID — already pre-configured in Shibboleth |
| `SpAcsUrl` | SP ACS URL — already pre-configured in Shibboleth |
| `InstanceId` | EC2 instance ID for SSM Session Manager access |
| `ElasticIp` | Public IP address |
| `ConfigBucket` | S3 bucket holding config files |

---

## Registering the IdP in Cognito

1. Open AWS Console → Cognito → User pools → your pool
2. Left nav: **Authentication → Social and external providers → Add identity provider → SAML**
3. Fill in:
   - **Provider name:** `SSOSim-qa` (this becomes the `identity_provider` param)
   - **Metadata document URL:** value of `IdpMetadataUrl` output
   - **IdP-initiated sign-in:** Off
4. **Attribute mapping:** Cognito `email` → SAML attribute `email`
5. In the App Client → **Login pages** tab → add `ShibbolethTestIdP` to Identity providers
6. In the backend Organization record, set `ssoIdpName = ShibbolethTestIdP` and the test user's email domain

---

## Connecting to the EC2 (no SSH key needed)

The instance has SSM Session Manager enabled. Connect via:

```bash
aws ssm start-session --target <InstanceId>
```

Useful commands once connected:

```bash
# View Shibboleth startup log
cat /var/log/shibboleth-startup.log

# View live Shibboleth logs
docker logs -f shibboleth-idp

# Apply a config change (sync S3 config + restart container)
source /etc/shibboleth-env.sh
bash /opt/shibboleth-config/start-shibboleth.sh

# Check nginx
systemctl status nginx
nginx -t
```

---

## Updating Config

`cdk deploy` is safe to re-run at any time — it is idempotent and only updates what changed. For config-only changes it just syncs the new files to S3 and skips the EC2, security group, and Route 53 resources.

**To update any config file (e.g. add a test user, add a Cognito IdP):**

```bash
# 1. Edit the file locally
htpasswd -B cdk/config/users.htpasswd newuser@example.com

# 2. Upload to S3
aws s3 cp cdk/config/users.htpasswd s3://sso-sim-shibboleth-config-623586450996/config/users.htpasswd
# (or re-deploy everything: cd cdk && cdk deploy)

# 3. Connect to the EC2 and apply
aws ssm start-session --target <InstanceId>
# On the EC2:
source /etc/shibboleth-env.sh
bash /opt/shibboleth-config/start-shibboleth.sh
```

`start-shibboleth.sh` syncs config from S3, rebuilds the conf directory, and restarts the container. The EC2 instance keeps running — no stop/start needed.

**To run the full first-time setup** (e.g. on a freshly launched EC2):

```bash
aws ssm start-session --target <InstanceId>
# On the EC2:
aws s3 cp s3://sso-sim-shibboleth-config-623586450996/config/startup.sh /tmp/startup.sh
bash /tmp/startup.sh 2>&1 | tee /var/log/shibboleth-startup.log
```

`startup.sh` installs packages, generates/restores credentials, configures nginx with a Let's Encrypt cert, and starts Shibboleth. Takes ~5–10 minutes.

---

## Cost Management

Stop the EC2 when not actively testing:

```bash
# Stop (billing for compute stops; Elastic IP charge applies ~$0.005/hr while stopped)
aws ec2 stop-instances --instance-ids <InstanceId>

# Start again
aws ec2 start-instances --instance-ids <InstanceId>
```

Destroy everything when no longer needed:

```bash
cd cdk && cdk destroy
```

---

## File Structure

```
SSO-sim/
├── README.md
└── cdk/
    ├── app.py                       # CDK app entry point
    ├── cdk.json                     # Config — fill in domain_name and cognito_user_pool_id
    ├── requirements.txt
    ├── stacks/
    │   └── shibboleth_idp_stack.py  # CDK stack — EC2, S3, Route53, Elastic IP
    └── config/                      # Shibboleth config — uploaded to S3 on deploy
        ├── authn/
        │   └── password-authn-config.xml  # htpasswd authentication (overrides LDAP default)
        ├── attribute-resolver.xml   # Defines email attribute from htpasswd username
        ├── attribute-filter.xml     # Releases email to Cognito SP
        ├── cognito-sp-metadata.xml  # Cognito SP metadata (entity ID + ACS URL)
        ├── metadata-providers.xml   # Registers Cognito as Service Provider
        ├── users.htpasswd           # Test users — email:bcrypt_hash
        ├── nginx.conf               # nginx reverse proxy config
        ├── startup.sh               # EC2 user-data orchestrator — installs packages, calls the three scripts below
        ├── setup-shibboleth.sh      # One-time: generate/restore credentials from S3, configure Jetty
        ├── start-shibboleth.sh      # Re-runnable: sync S3 config, rebuild conf dir, restart container
        └── startup-nginx.sh         # One-time: acquire Let's Encrypt cert, configure and start nginx
```

---

## Troubleshooting

| Problem | Steps |
|---|---|
| IdP metadata URL returns 502 | Shibboleth still starting — wait 3–5 min after EC2 start, check `docker logs shibboleth-idp` |
| Let's Encrypt cert fails | Ensure port 80 is open in the security group and DNS A record has propagated |
| Login fails with wrong password | Regenerate htpasswd entry with `htpasswd -B`, upload to S3, run `start-shibboleth.sh` on EC2 |
| Cognito can't fetch IdP metadata | Ensure EC2 is fully started and `docker logs shibboleth-idp` shows no errors before saving in Cognito |
| `cdk deploy` fails on domain_name | Set `domain_name` to a domain whose hosted zone exists in Route 53 |
| EC2 startup log | `cat /var/log/shibboleth-startup.log` via SSM Session Manager |

---

## Adding the IdP in Cognito Console

> Before doing this, verify Shibboleth is fully running: `docker logs shibboleth-idp` should show no errors and the metadata URL (`IdpMetadataUrl` output) should return XML in the browser.

**Console:** Cognito → User pools → your pool → **Authentication → Social and external providers → Add identity provider → SAML**

### Step 1 — Provider details

| Field | Value |
|---|---|
| **Provider name** | Choose a name, e.g. `SSOSim-qa` — this becomes the `identity_provider` param in the authorize URL |
| **Identifiers** | Leave blank |
| **Sign-out flow** | Leave unchecked |
| **IdP-initiated SAML sign-in** | Leave as "Require SP-initiated SAML assertions - Recommended" |
| **Metadata document source** | Select **Metadata document endpoint URL** |
| **Metadata document** | Value of the `IdpMetadataUrl` stack output, e.g. `https://ssosim-qa.trialpro.ai/idp/shibboleth` |
| **SAML signing and encryption** | Leave unchecked |

### Step 2 — Map attributes

| User pool attribute | SAML attribute |
|---|---|
| `email` | `email` |

Click **Add identity provider**.

### Step 3 — Allow the IdP on the App Client

**Console:** Applications → App clients → your client → **Login pages** tab → Edit → add the provider name (e.g. `SSOSim-qa`) to **Identity providers** → Save.

### Step 4 — Configure the backend Organization record

Set the Organization's `ssoIdpName` to match the provider name exactly (e.g. `SSOSim-qa`) and set the email domain for the test users.
