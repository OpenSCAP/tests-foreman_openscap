#!/bin/bash
set -x
set -e -o pipefail

source ./lib.sh

ghdir="/tmp/github"
mkdir -p $ghdir

vmname=foreman-nightly
host=${vmname}.local.lan

local_requires
ensure_sshkey_exists
deploy_foreman_nightly_start $vmname
clone_upstreams &
deploy_foreman_wait $host
deploy_rubygem_openscap $host
deploy_scaptimony $host
deploy_foreman_openscap $host
deploy_smart_proxy_openscap $host
deploy_foreman_scap_client $host
deploy_puppet_foreman_scap_client $host

import_puppet_foreman_scap_client $host

test_foreman_openscap $host
