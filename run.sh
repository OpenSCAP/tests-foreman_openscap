#!/bin/bash
set -x
set -e -o pipefail

source ./lib.sh

ghdir="~/data/redhat/git/hub"
vmname=foreman17test
host=${vmname}.local.lan

local_requires
deploy_foreman17_start $vmname
deploy_foreman17_wait $host
patch_foreman17
deploy_rubygem_openscap
deploy_scaptimony $host
deploy_foreman_openscap $host
deploy_smart_proxy_openscap $host
deploy_foreman_scap_client $host
deploy_puppet_foreman_scap_client $host

