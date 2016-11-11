#!/bin/bash

set -e -x

source /etc/profile.d/chruby.sh
chruby 2.1

export BUNDLE_GEMFILE="${PWD}/bosh-src/Gemfile"

bundle install --local

bosh() {
  bundle exec bosh -n -t "${BOSH_DIRECTOR_ADDRESS}" "$@"
}

# login
bosh login "${BOSH_DIRECTOR_USERNAME}" "${BOSH_DIRECTOR_PASSWORD}"

cleanup() {
  bosh cleanup --all
}
trap cleanup EXIT

# bosh upload stemcell
pushd stemcell
  bosh upload stemcell ./*.tgz
popd

# bosh upload release (syslog)
pushd syslog-release
  bosh create release
  bosh upload release
popd

env_attr() {
  local json=$1
  echo $json | jq --raw-output --arg attribute $2 '.[$attribute]'
}

metadata=$(cat environment/metadata)
network=$(env_attr "${metadata}" "network1")

: ${STEMCELL_TEST_VLAN:=$(                          env_attr "${network}" "vCenterVLAN")}
: ${STEMCELL_TEST_CIDR:=$(                          env_attr "${network}" "vCenterCIDR")}
: ${STEMCELL_TEST_RESERVED_RANGE:=$(                env_attr "${network}" "reservedRange")}
: ${STEMCELL_TEST_GATEWAY:=$(                       env_attr "${network}" "vCenterGateway")}

#Build Cloud config
cat > "./cloud-config.yml" <<EOF
azs:
- name: z1
  cloud_properties:
    datacenters:
    - name: ${BOSH_VSPHERE_VCENTER_DC}
      clusters:
        - ${BOSH_VSPHERE_VCENTER_CLUSTER}: {}

vm_types:
- name: default
  cloud_properties:
    ram: 2048
    cpu: 1
    disk: 5120

networks:
- name: default
  type: manual
  subnets:
  - range: ${STEMCELL_TEST_CIDR}
    reserved: [${STEMCELL_TEST_RESERVED_RANGE}]
    gateway: ${STEMCELL_TEST_GATEWAY}
    az: z1
    cloud_properties:
      name: ${STEMCELL_TEST_VLAN}

compilation:
  workers: 2
  reuse_compilation_vms: true
  az: z1
  vm_type: default
  network: default
EOF

bosh update cloud-config ./cloud-config.yml

# build manifest
cat > "./deployment.yml" <<EOF
---
name: bosh-stemcell-smoke-tests
director_uuid: $(bosh status --uuid)

releases:
- name: syslog
  version: latest

stemcells:
- alias: default
  os: ubuntu-trusty
  version: $(cat stemcell/version)

update:
  canaries: 1
  max_in_flight: 10
  canary_watch_time: 1000-30000
  update_watch_time: 1000-30000

instance_groups:
- name: syslog_storer
  stemcell: default
  vm_type: default
  instances: 1
  networks:
  - {name: default}
  azs: [z1]
  jobs:
  - name: syslog_storer
    release: syslog
    properties:
      syslog:
        transport: udp
        port: 514
- name: syslog_forwarder
  stemcell: default
  vm_type: default
  azs: [z1]
  instances: 1
  networks:
  - {name: default}
  jobs:
  - name: syslog_forwarder
    release: syslog
    properties:
      syslog:
        forward_files: true
    consumes:
      syslog_storer: { from: syslog_storer }
EOF

cleanup() {
  bosh delete deployment bosh-stemcell-smoke-tests
  bosh cleanup --all
}

bosh -d ./deployment.yml deploy

## trigger auditd event
#bosh -d ./deployment.yml ssh syslog_forwarder 0 'sudo modprobe -r floppy'
#bosh -d ./deployment.yml ssh syslog_forwarder 0 'logger -t vcap some vcap message'
#
## check that syslog drain gets event
#DOWNLOAD_DESTINATION=$(mktemp -d -t)
#bosh -d ./deployment.yml scp --download syslog_storer 0 /var/vcap/store/syslog_storer/syslog.log ${DOWNLOAD_DESTINATION}
#
#grep 'COMMAND=/sbin/modprobe -r floppy' ${DOWNLOAD_DESTINATION}/syslog.log.syslog_storer.0 || ( echo "Syslog did not contain 'audit'!" ; exit 1 )
#grep 'some vcap message' ${DOWNLOAD_DESTINATION}/syslog.log.syslog_storer.0 || ( echo "Syslog did not contain 'vcap'!" ; exit 1 )
#
#
##fill the syslog so it will need rotating and set cron to run logrotate every min
#bosh -d ./deployment.yml ssh syslog_forwarder 0 'logger "old syslog content" \
#	&& sudo bash -c "dd if=/dev/urandom count=10000 bs=1024 >> /var/log/syslog" \
#	&& sudo sed -i "s/0,15,30,45/\*/" /etc/cron.d/logrotate'
## wait for cron to run logrotate
#sleep 62
#bosh -d ./deployment.yml ssh syslog_forwarder 0 'logger "new syslog content"'
#bosh -d ./deployment.yml ssh syslog_forwarder 0 'sudo cp /var/vcap/data/root_log/syslog /tmp/ && sudo chmod 777 /tmp/syslog'
#
#DOWNLOAD_DESTINATION=$(mktemp -d -t)
##/var/log should be bind mounted to /var/vcap/data/root_log
## download from there to show rsyslogd is running and logging to the bind mounted directory.
#bosh -d ./deployment.yml scp --download syslog_forwarder 0 /tmp/syslog ${DOWNLOAD_DESTINATION}
#grep 'new syslog content' ${DOWNLOAD_DESTINATION}/syslog.* || ( echo "logrotate did not rotate syslog and restart rsyslogd successfully" ; exit 1 )
#grep -vl 'old syslog content' ${DOWNLOAD_DESTINATION}/syslog.* || ( echo "syslog contains content that should have been rotated" ; exit 1 )
#

# testing log forwarding
#DOWNLOAD_DESTINATION=$(mktemp -d -t)
#
#bosh -d ./deployment.yml ssh syslog_forwarder 0 "logger syslog-forwarder-test-msg"
#bosh -d ./deployment.yml scp --download syslog_storer 0 /var/vcap/store/syslog_storer/syslog.log ${DOWNLOAD_DESTINATION}
#
#grep 'syslog-forwarder-test-msg' ${DOWNLOAD_DESTINATION}/syslog.* || ( echo "was not able to get logs from syslog" ; exit 1 )

# testing deep log forwarding
DOWNLOAD_DESTINATION=$(mktemp -d -t)
MONIT_SUMMARY_OUTPUT=$(mktemp -d -t)
LOGFILE=/var/vcap/sys/log/deep/path/deepfile.log


touch /tmp/localsummary
bosh -d ./deployment.yml ssh syslog_forwarder 0 "echo c1oudc0w | sudo -S /var/vcap/bosh/bin/monit summary | sudo tee -a ${MONIT_SUMMARY_OUTPUT}"
sleep 5
bosh -d ./deployment.yml scp --download syslog_forwarder 0 "${MONIT_SUMMARY_OUTPUT}" /tmp/localsummary
sleep 5
cat /tmp/localsummary

bosh -d ./deployment.yml ssh syslog_forwarder 0 "echo c1oudc0w | sudo -S mkdir -p /var/vcap/sys/log/deep/path"
sleep 5
bosh -d ./deployment.yml ssh syslog_forwarder 0 "echo c1oudc0w | sudo -S touch ${LOGFILE}"
sleep 5
bosh -d ./deployment.yml ssh syslog_forwarder 0 "echo c1oudc0w | sudo -S echo 'test-deep-blackbox-msg' | sudo tee -a ${LOGFILE}"
sleep 5
bosh -d ./deployment.yml scp --download syslog_storer 0 "/var/vcap/store/syslog_storer/syslog.log" "${DOWNLOAD_DESTINATION}"

grep 'test-deep-blackbox-msg' ${DOWNLOAD_DESTINATION}/syslog.* || ( echo "was not able to get message forwarded from BlackBox" ; exit 1 )
