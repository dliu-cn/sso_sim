"""
Shibboleth Test IdP Stack.

Provisions an EC2 t3.small running a Shibboleth IdP in Docker behind nginx
(Let's Encrypt TLS). Registers Cognito as the Service Provider. Used to
simulate a university SSO (e.g. UNC) during development of the SSO feature.

Cost: ~$17/month always-on. Stop the EC2 instance when not testing.

Deploy:
    pip install -r requirements.txt
    cdk bootstrap aws://ACCOUNT/REGION   # first time only
    cdk deploy

Fill in cdk.json before deploying:
    domain_name           - Route 53 hosted zone you own
    idp_subdomain         - subdomain for the IdP  (default: test-idp)
    cognito_user_pool_id  - Cognito User Pool ID (e.g. us-east-1_ohhKRMdJp)
"""
import os
from aws_cdk import (
    Stack,
    Tags,
    CfnOutput,
    RemovalPolicy,
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_s3 as s3,
    aws_s3_deployment as s3deploy,
    aws_route53 as route53,
    aws_route53_targets as route53_targets,
)
from constructs import Construct


class ShibbolethIdpStack(Stack):

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # ── Context ──────────────────────────────────────────────────
        vpc_id              = self.node.try_get_context("vpc_id")
        domain_name         = self.node.try_get_context("domain_name")
        idp_subdomain       = self.node.try_get_context("idp_subdomain") or "test-idp"
        cognito_pool_id     = self.node.try_get_context("cognito_user_pool_id")
        cognito_region      = self.node.try_get_context("cognito_region") or self.region
        cognito_hosted_domain = self.node.try_get_context("cognito_hosted_domain")

        if not domain_name or domain_name == "FILL_IN_YOUR_DOMAIN":
            raise ValueError("Set 'domain_name' in cdk.json before deploying.")
        if not cognito_pool_id or cognito_pool_id == "FILL_IN_USER_POOL_ID":
            raise ValueError("Set 'cognito_user_pool_id' in cdk.json before deploying.")
        if not cognito_hosted_domain:
            raise ValueError("Set 'cognito_hosted_domain' in cdk.json (e.g. myapp.auth.us-east-1.amazoncognito.com).")

        idp_hostname = f"{idp_subdomain}.{domain_name}"
        cognito_sp_entity_id = f"urn:amazon:cognito:sp:{cognito_pool_id}"
        cognito_sp_acs_url   = f"https://{cognito_hosted_domain}/saml2/idpresponse"

        Tags.of(self).add("Environment", "test")
        Tags.of(self).add("Application", "SSOSimulator")
        Tags.of(self).add("ManagedBy", "CDK")

        # ── VPC ──────────────────────────────────────────────────────
        vpc = ec2.Vpc.from_lookup(self, "Vpc", vpc_id=vpc_id)

        # ── S3 bucket for Shibboleth config ──────────────────────────
        config_bucket = s3.Bucket(
            self, "ShibbolethConfig",
            bucket_name=f"sso-sim-shibboleth-config-{self.account}",
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
        )

        config_dir = os.path.join(os.path.dirname(__file__), "..", "config")
        s3deploy.BucketDeployment(
            self, "DeployConfig",
            sources=[s3deploy.Source.asset(config_dir)],
            destination_bucket=config_bucket,
            destination_key_prefix="config",
        )

        # ── IAM Role ─────────────────────────────────────────────────
        role = iam.Role(
            self, "InstanceRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name(
                    "AmazonSSMManagedInstanceCore"  # SSM Session Manager — no SSH key needed
                ),
            ],
        )
        config_bucket.grant_read_write(role)  # write needed to upload generated credentials to S3

        # ── Security Group ────────────────────────────────────────────
        sg = ec2.SecurityGroup(
            self, "ShibbolethSG",
            vpc=vpc,
            description="Shibboleth test IdP",
            allow_all_outbound=True,
        )
        sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(443),  "HTTPS")
        sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80),   "HTTP - Lets Encrypt challenge")
        sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(22),   "SSH (optional)")

        # ── EC2 User Data ─────────────────────────────────────────────
        user_data = ec2.UserData.for_linux()
        user_data.add_commands(
            "set -euo pipefail",
            f"export IDP_HOSTNAME={idp_hostname}",
            f"export S3_BUCKET={config_bucket.bucket_name}",
            f"export COGNITO_POOL_ID={cognito_pool_id}",
            f"export COGNITO_REGION={cognito_region}",
            f"export COGNITO_SP_ENTITY_ID={cognito_sp_entity_id}",
            f"export COGNITO_SP_ACS_URL={cognito_sp_acs_url}",
            # Download and run the startup script from S3
            "aws s3 cp s3://$S3_BUCKET/config/startup.sh /tmp/startup.sh",
            "chmod +x /tmp/startup.sh",
            "bash /tmp/startup.sh 2>&1 | tee /var/log/shibboleth-startup.log",
        )

        # ── EC2 Instance ──────────────────────────────────────────────
        instance = ec2.Instance(
            self, "ShibbolethIdp",
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.T3, ec2.InstanceSize.SMALL
            ),
            machine_image=ec2.MachineImage.latest_amazon_linux2023(),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            security_group=sg,
            role=role,
            user_data=user_data,
            block_devices=[
                ec2.BlockDevice(
                    device_name="/dev/xvda",
                    volume=ec2.BlockDeviceVolume.ebs(20),  # 20 GB — enough for Docker images
                )
            ],
        )

        # ── Elastic IP ────────────────────────────────────────────────
        eip = ec2.CfnEIP(self, "ElasticIP", instance_id=instance.instance_id)

        # ── Route 53 ──────────────────────────────────────────────────
        hosted_zone = route53.HostedZone.from_lookup(
            self, "HostedZone", domain_name=domain_name
        )
        route53.ARecord(
            self, "IdpARecord",
            zone=hosted_zone,
            record_name=idp_subdomain,
            target=route53.RecordTarget.from_ip_addresses(eip.ref),
        )

        # ── Outputs ───────────────────────────────────────────────────
        CfnOutput(self, "IdpHostname",
            value=idp_hostname,
            description="Public hostname of the test IdP")

        CfnOutput(self, "IdpMetadataUrl",
            value=f"https://{idp_hostname}/idp/shibboleth",
            description="SAML metadata URL — paste into Cognito console when registering the IdP")

        CfnOutput(self, "IdpSsoUrl",
            value=f"https://{idp_hostname}/idp/profile/SAML2/Redirect/SSO",
            description="IdP SSO endpoint")

        CfnOutput(self, "SpEntityId",
            value=cognito_sp_entity_id,
            description="SP Entity ID to register in Shibboleth (already pre-configured)")

        CfnOutput(self, "SpAcsUrl",
            value=cognito_sp_acs_url,
            description="SP ACS URL to register in Shibboleth (already pre-configured)")

        CfnOutput(self, "InstanceId",
            value=instance.instance_id,
            description="EC2 instance ID — use with SSM Session Manager to connect without SSH")

        CfnOutput(self, "ElasticIp",
            value=eip.ref,
            description="Elastic IP address")

        CfnOutput(self, "ConfigBucket",
            value=config_bucket.bucket_name,
            description="S3 bucket holding Shibboleth config — edit files here and re-run startup.sh to apply")
