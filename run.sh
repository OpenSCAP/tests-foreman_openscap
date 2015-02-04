#!/bin/bash
set -x
set -e -o pipefail

ghdir="~/data/redhat/git/hub"

cd $ghdir/lzap/bin-public
./virt-spawn --force -n foreman17 --  "FOREMAN_REPO=releases/1.7"
bash
host=foreman17.local.lan
ssh root@$host '
	cd /etc/yum.repos.d/ \
	&& wget https://copr.fedoraproject.org/coprs/isimluk/OpenSCAP/repo/epel-6/isimluk-OpenSCAP-epel-6.repo \
	&& yum install openscap-utils ruby193-rubygem-openscap -y \
'
scp $ghdir/theforeman/foreman/0001-Fixes-8052-allows-erb-in-array-and-hash-params.patch root@$host:
ssh root@$host '
	cd ~foreman \
	&& patch -p1 ~/0001*
	'
cd $ghdir/scaptimony
./deploy $host
cd ../foreman_openscap
./deploy $host
cd ../smart_proxy_openscap
./deploy $host
cd ../foreman_scap_client
./deploy $host
cd ../puppet-foreman_scap_client
./deploy
