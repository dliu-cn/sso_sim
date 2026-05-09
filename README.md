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

Edit `cdk/config/authn/users.properties`. This is the file Shibboleth uses for login authentication (via the Jetty JAAS `PropertyFileLoginModule`). Usernames must be email addresses that match UserInfo records in the TrialPro backend DB.

Format: `email: password,role`

```
john@unc-sim.edu: 1234,user
jane@unc-sim.edu: 1234,user
```

> **Note:** `cdk/config/users.htpasswd` is used by nginx for unrelated HTTP basic auth paths and has **no effect** on who can log in via the Shibboleth login form. Editing it will not add or remove SSO test users.

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
   - **Sign-out flow:** Enable (required for SLO testing)
   - **IdP-initiated sign-in:** Off
4. **Attribute mapping:**
   - Cognito `email` → SAML attribute `email`
   - Cognito `custom:externalUserId` → SAML attribute `NAMEID`
5. In the App Client → **Login pages** tab → add the provider to Identity providers, and add `http://localhost:3000/login` to Allowed sign-out URLs
6. In the backend Organization record, set `ssoIdpName = SSOSim-qa` and the test user's email domain

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

**To add or remove a test user:**

```bash
# 1. Edit cdk/config/authn/users.properties
#    Format: email: password,role
#    e.g.  newuser@unc-sim.edu: 1234,user

# 2. Upload to S3
aws s3 cp cdk/config/authn/users.properties s3://sso-sim-shibboleth-config-623586450996/config/authn/users.properties

# 3. Connect to the EC2 and apply
aws ssm start-session --target <InstanceId>
# On the EC2:
source /etc/shibboleth-env.sh
bash /opt/shibboleth-config/start-shibboleth.sh
```

**To update any other config file (e.g. add a Cognito IdP):**

```bash
# 1. Edit the file locally
# 2. Upload to S3
aws s3 cp cdk/config/<file> s3://sso-sim-shibboleth-config-623586450996/config/<file>
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
        │   ├── password-authn-config.xml  # Configures Shibboleth to use JAAS for password auth
        │   ├── jaas.config                # Points JAAS to users.properties for login
        │   └── users.properties           # ⬅ Test user accounts — format: email: password,role
        ├── attribute-resolver.xml   # Defines email attribute from authenticated username
        ├── attribute-filter.xml     # Releases email to Cognito SP
        ├── cognito-sp-metadata.xml  # Cognito SP metadata (entity ID + ACS URL)
        ├── metadata-providers.xml   # Registers Cognito as Service Provider
        ├── users.htpasswd           # nginx HTTP basic auth — NOT used for Shibboleth login
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
| Login fails with wrong password | Edit `cdk/config/authn/users.properties`, upload to S3, run `start-shibboleth.sh` on EC2 |
| Cognito can't fetch IdP metadata | Ensure EC2 is fully started and `docker logs shibboleth-idp` shows no errors before saving in Cognito |
| `cdk deploy` fails on domain_name | Set `domain_name` to a domain whose hosted zone exists in Route 53 |
| EC2 startup log | `cat /var/log/shibboleth-startup.log` via SSM Session Manager |
| SLO: Shibboleth returns 400 on LogoutRequest | Cognito signing cert missing from `cognito-sp-metadata.xml` — retrieve with `aws cognito-idp get-signing-certificate` and add as `KeyDescriptor use="signing"` |
| SLO: Cognito returns 400 at `/saml2/logout?SAMLResponse=...` | SAMLResponse status is `UnknownPrincipal` (secondary index empty) or LogoutResponse was sent via HTTP-Redirect instead of HTTP-POST. Check: (1) `global.xml` defines `shibboleth.ServerSideStorage` and `idp.properties` sets `idp.session.StorageService = shibboleth.ServerSideStorage`; (2) `SingleLogoutService` binding in `cognito-sp-metadata.xml` is `HTTP-POST`; (3) container was restarted after login — re-login and retry |
| SLO: Cognito receives LogoutResponse but doesn't redirect to `logout_uri` | Cognito has a stale Shibboleth signing cert cached — run `update-identity-provider` with the `MetadataURL` to force a re-fetch (see SLO section above) |
| SLO: `logout_uri` not redirected | Ensure `logout_uri` is listed exactly in the App Client's Allowed sign-out URLs |

---

## Adding the IdP in Cognito Console

> Before doing this, verify Shibboleth is fully running: `docker logs shibboleth-idp` should show no errors and the metadata URL (`IdpMetadataUrl` output) should return XML in the browser.

**Console:** Cognito → User pools → your pool → **Authentication → Social and external providers → Add identity provider → SAML**

### Step 1 — Provider details

| Field | Value |
|---|---|
| **Provider name** | Choose a name, e.g. `SSOSim-qa` — this becomes the `identity_provider` param in the authorize URL |
| **Identifiers** | Leave blank |
| **Sign-out flow** | **Enable** — required for SLO (logout propagation to Shibboleth) |
| **IdP-initiated SAML sign-in** | Leave as "Require SP-initiated SAML assertions - Recommended" |
| **Metadata document source** | Select **Metadata document endpoint URL** |
| **Metadata document** | Value of the `IdpMetadataUrl` stack output, e.g. `https://ssosim-qa.trialpro.ai/idp/shibboleth` |
| **SAML signing and encryption** | Leave unchecked |

### Step 2 — Map attributes

| User pool attribute | SAML attribute |
|---|---|
| `email` | `email` |
| `custom:externalUserId` | `NAMEID` |

Click **Add identity provider**.

### Step 3 — Allow the IdP on the App Client

**Console:** Applications → App clients → your client → **Login pages** tab → Edit:
- Add the provider name (e.g. `SSOSim-qa`) to **Identity providers**
- Add `http://localhost:3000/login` to **Allowed sign-out URLs** (required for SLO to redirect back to the app after logout)

### Step 4 — Configure the backend Organization record

Set the Organization's `ssoIdpName` to match the provider name exactly (e.g. `SSOSim-qa`) and set the email domain for the test users.

---

## SLO (Single Logout) — How It Works and What Was Required

Shibboleth SLO with Cognito required several non-obvious configuration steps. Documented here to avoid re-discovering them.

### SLO Flow

```
App → GET /logout?client_id=...&logout_uri=http://localhost:3000/login
  → Cognito clears session, sends signed SAMLRequest (LogoutRequest) to Shibboleth SLO endpoint
  → Browser redirects: GET https://{idp}/idp/profile/SAML2/Redirect/SLO?SAMLRequest=...
  → Shibboleth verifies signature, terminates session, sends SAMLResponse (LogoutResponse)
  → Browser POSTs to: https://{cognito}/saml2/logout  (HTTP-POST binding — see below)
  → Cognito verifies LogoutResponse, redirects browser to logout_uri
```

### Required Configuration

**1. Cognito SP signing certificate in `cognito-sp-metadata.xml`**

Cognito signs its LogoutRequests. Without the Cognito signing cert in the SP metadata, Shibboleth cannot verify the signature and rejects the request with 400. Retrieve the cert and add it as `KeyDescriptor use="signing"`:

```bash
aws cognito-idp get-signing-certificate --user-pool-id <pool-id> --region us-east-1
```

This cert is already configured in `cdk/config/cognito-sp-metadata.xml`.

**2. HTTP-POST binding for the SP SLO endpoint**

Cognito's `/saml2/logout` endpoint only accepts **POST** for incoming LogoutResponses. Using HTTP-Redirect (GET) returns `400 Allow: POST`. The `SingleLogoutService` in the SP metadata must specify `HTTP-POST` binding:

```xml
<md:SingleLogoutService
    Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
    Location="https://{cognito}/saml2/logout"/>
```

This is already configured in `cdk/config/cognito-sp-metadata.xml`.

**3. Server-side session storage — `global.xml` + `idp.session.StorageService`**

Shibboleth 3.4.x in the Docker image defaults to **client-side (cookie-based) session storage** (`isServerSide() = false`). With client-side storage, `StorageBackedIdPSession.addSPSession()` silently fails, the secondary index is never populated, and every SLO request returns `UnknownPrincipal`.

The fix is `cdk/config/global.xml`, which defines an explicit `MemoryStorageService` bean (`shibboleth.ServerSideStorage`), and `idp.properties` which points `idp.session.StorageService` to it:

```xml
<!-- global.xml -->
<bean id="shibboleth.ServerSideStorage"
    class="org.opensaml.storage.impl.MemoryStorageService"
    p:cleanupInterval="PT10M" />
```

```properties
# idp.properties
idp.session.StorageService = shibboleth.ServerSideStorage
```

Overriding the system bean `shibboleth.StorageService` in-place (same ID) does **not** work — Shibboleth protects system bean definitions from user-space redefinition. A distinct name that the session manager can look up across all loaded beans is required.

**4. SP session tracking and secondary index**

SLO in Shibboleth 3.x uses the secondary index to find the IdP session — there is no cookie-based fallback in the SLO profile. The following `idp.properties` settings are required:

```properties
idp.session.trackSPSessions = true     # writes SP session records at assertion issuance
idp.session.secondaryServiceIndex = true  # maintains the SP+NameID → session ID index
```

Both are set and confirmed working: login produces `Maintaining secondary index for service ID ... and key {email}` in the log, and logout finds it with `Performing secondary lookup ... → LogoutRequest matches IdP session`.

**5. NameID format must be `persistent` end-to-end**

Cognito always sends `persistent` format in LogoutRequests. The secondary index key includes the NameID format; a mismatch causes `SessionNotFound`. The NameID generator in `saml-nameid.xml` is configured to emit `persistent` format to match.

**6. Shibboleth sessions are in-memory**

`MemoryStorageService` stores sessions in process memory. A container restart clears all sessions. If Shibboleth receives a LogoutRequest for a session it no longer knows about, it returns `UnknownPrincipal` — Cognito then returns 400 instead of redirecting to `logout_uri`.

**Rule:** After any container restart (e.g. after a config change), always re-login before testing SLO. The Cognito session from before the restart is stale anyway.

**4. Cognito caches the Shibboleth signing cert**

When you register the IdP in Cognito using a metadata URL, Cognito fetches and caches the Shibboleth signing cert. If the Shibboleth credentials are regenerated (e.g. on a fresh EC2), the cached cert becomes stale and Cognito silently fails to verify LogoutResponses (no redirect to `logout_uri`).

Force a metadata refresh whenever Shibboleth credentials change:

```bash
aws cognito-idp update-identity-provider \
  --user-pool-id <pool-id> \
  --provider-name <provider-name> \
  --provider-details '{"MetadataURL": "https://{idp}/idp/shibboleth", "IDPSignout": "true"}' \
  --region us-east-1
```
