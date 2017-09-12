#!/usr/bin/env bash
set -e

source /etc/profile.d/chruby.sh

chruby 2.2.4

: ${INFRASTRUCTURE:?}
: ${SL_VM_PREFIX:?}
: ${SL_VM_DOMAIN:?}
: ${SL_USERNAME:?}
: ${SL_API_KEY:?}
: ${SL_DATACENTER:?}
: ${SL_VLAN_PUBLIC:?}
: ${SL_VLAN_PRIVATE:?}
: ${CF_PREFIX:?}

cp bosh-cli-v2/bosh-cli-* /usr/local/bin/bosh-cli
chmod +x /usr/local/bin/bosh-cli

deployment_dir="${PWD}/deployment"
mkdir -p $deployment_dir
chmod +x bosh-cli-v2/bosh-cli*

echo -e "\n\033[32m[INFO] Using bosh-cli $(bosh-cli -v).\033[0m"
echo -e "\n\033[32m[INFO] Generating director yml.\033[0m"
cat >remove_variables.yml <<EOF
- type: remove
  path: /variables
EOF

cat >remove-health-monitor.yml <<EOF
- path: /instance_groups/name=bosh/jobs/name=health_monitor
  type: remove
EOF

echo -e "\n\033[32m[INFO] Generating manifest director.yml.\033[0m"
bosh-cli int bosh-deployment/bosh.yml \
	-o bosh-deployment/$INFRASTRUCTURE/cpi-base.yml \
	-o bosh-deployment/$INFRASTRUCTURE/dynamic-director.yml \
	-o bosh-deployment/jumpbox-user.yml \
	-o ./remove-health-monitor.yml \
	-v internal_ip=$SL_VM_PREFIX.$SL_VM_DOMAIN \
	-v dns_recursor_ip=$SL_VM_PREFIX.$SL_VM_DOMAIN \
	-v director_name=bats-director \
	-v sl_director_fqn=$SL_VM_PREFIX.$SL_VM_DOMAIN \
	-v sl_datacenter=$SL_DATACENTER \
	-v sl_vlan_public=$SL_VLAN_PUBLIC \
	-v sl_vlan_private=$SL_VLAN_PRIVATE \
	-v sl_vm_name_prefix=$SL_VM_PREFIX \
	-v sl_vm_domain=$SL_VM_DOMAIN \
	-v sl_username=$SL_USERNAME \
	-v sl_api_key=$SL_API_KEY \
	--vars-store ${deployment_dir}/director-creds.yml \
	>${deployment_dir}/director.yml

echo -e "\n\033[32m[INFO] Deploying director.\033[0m"
bosh-cli create-env \
	--state=${deployment_dir}/director-state.json \
	--vars-store ${deployment_dir}/director-creds.yml \
	${deployment_dir}/director.yml

echo -e "\n\033[32m[INFO] Deployed director successfully:\033[0m"
cat /etc/hosts | grep "$SL_VM_DOMAIN" | tee ${deployment_dir}/director-hosts

echo -e "\n\033[32m[INFO] Updating cloud-config.\033[0m"
export BOSH_ENVIRONMENT=$(awk '{if ($2!="") print $2}' ${deployment_dir}/director-hosts)
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$(bosh-cli int ${deployment_dir}/director-creds.yml --path /admin_password)
export BOSH_CA_CERT=$(bosh-cli int ${deployment_dir}/director-creds.yml --path /default_ca/ca)

bosh-cli update-cloud-config -n ./bosh-deployment/${INFRASTRUCTURE}/cloud-config.yml \
	-o ./bosh-softlayer-tools/ci/softlayer_ng/ops/cloud-config-plus.yml \
	-v sl_datacenter=${SL_DATACENTER} \
	-v sl_vm_name_prefix=${CF_PREFIX} \
	-v sl_vm_domain=${SL_VM_DOMAIN} \
	-v internal_cidr=10.0.0.0/24 \
	-v internal_gw=10.0.0.1 \
	-v sl_vlan_public_id=${SL_VLAN_PUBLIC} \
	-v sl_vlan_private_id=${SL_VLAN_PRIVATE}

echo -e "\n\033[32m[INFO] Final state of director deployment:\033[0m"
cat ${deployment_dir}/director-state.json

echo -e "\n\033[32m[INFO] Saving config.\033[0m"
cp bosh-cli-v2/bosh-cli* ${deployment_dir}/
pushd ${deployment_dir}
  tar -zcvf /tmp/director_artifacts.tgz ./ >/dev/null 2>&1
popd
mv /tmp/director_artifacts.tgz deploy-artifacts/
