#On local
aws s3 sync config  s3://sso-sim-shibboleth-config-623586450996/config
aws ssm start-session --target i-08e887e71c23448c0
#Now on AWS
sudo -i
aws s3 sync "s3://sso-sim-shibboleth-config-623586450996/config/" /opt/shibboleth-config/
source /etc/shibboleth-env.sh && bash /opt/shibboleth-config/start-shibboleth.sh
