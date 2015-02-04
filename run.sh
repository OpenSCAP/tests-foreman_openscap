#!/bin/bash
set -x
set -e -o pipefail

ghdir="~/data/redhat/git/hub"
vmname=foreman17test

function local_requires(){
	for pkg in virt-install libguestfs-tools-c
		rpm -q --quiet $pkg || yum install -y $pkg
	done
}

function deploy_foreman17(){
	cd $ghdir/lzap/bin-public
	./virt-spawn --force -n $vmname -- "FOREMAN_REPO=releases/1.7"
	host=$vmname.local.lan
	# wait for the installation to finish
	ssh root@host 'tail -f virt-sysprep-firstboot.log | grep "collect important logs"'
}

function patch_foreman17(){
	scp $ghdir/theforeman/foreman/0001-Fixes-8052-allows-erb-in-array-and-hash-params.patch root@$host:
	ssh root@$host '
		cd ~foreman \
		&& patch -p1 ~/0001*
		'
}

function deploy_rubygem_openscap(){
	ssh root@$host '
		cd /etc/yum.repos.d/ \
		&& wget https://copr.fedoraproject.org/coprs/isimluk/OpenSCAP/repo/epel-6/isimluk-OpenSCAP-epel-6.repo \
		&& yum install openscap-utils ruby193-rubygem-openscap -y \
		'
}

function deploy_scaptimony(){
	cd $ghdir/scaptimony
	./deploy $host
}

local_requires
deploy_foreman17
patch_foreman17
deploy_rubygem_openscap
deploy_scaptimony

cd ../foreman_openscap
./deploy $host
cd ../smart_proxy_openscap
./deploy $host
cd ../foreman_scap_client
./deploy $host
cd ../puppet-foreman_scap_client
./deploy
