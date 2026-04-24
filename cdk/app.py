#!/usr/bin/env python3
import aws_cdk as cdk
from stacks.shibboleth_idp_stack import ShibbolethIdpStack

app = cdk.App()

account = app.node.try_get_context("account") or "623586450996"
region  = app.node.try_get_context("region")  or "us-east-1"

ShibbolethIdpStack(
    app, "ShibbolethIdpStack",
    env=cdk.Environment(account=account, region=region),
)

app.synth()
