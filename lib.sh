#!/bin/bash

function local_requires(){
	for pkg in virt-install libguestfs-tools-c rubygems puppet fortune-mod; do
		rpm -q --quiet $pkg || sudo yum install -y $pkg
	done
	service libvirtd status || sudo service libvirtd start
	sudo mkdir -p /root/.cache/virt-builder
	clone_foreman_spawn
}

function ensure_sshkey(){
	local keyfile="$HOME/.ssh/id_rsa.pub"
	[ -f $keyfile ] || ssh-keygen -f $keyfile -t rsa -N ""
}

function clone_foreman_spawn(){
	[ -d $ghdir/lzap/bin-public ] && return
	pushd $ghdir
	mkdir -p lzap
	cd lzap
	git clone https://github.com/lzap/bin-public.git
	popd
}

function clone_upstreams(){
	pushd $ghdir
	mkdir -p openscap
	cd openscap
	for proj in scaptimony foreman_openscap smart_proxy_openscap foreman_scap_client puppet-foreman_scap_client; do
		if [ -d $proj ]; then
			cd $proj
			git pull --rebase
			cd -
		else
			git clone https://github.com/OpenSCAP/${proj}.git
		fi
	done
	cd ..
	mkdir -p theforeman
	cd theforeman
	[ -d foreman-packaging ] || git clone -b rpm/develop https://github.com/theforeman/foreman-packaging.git
	[ -d foreman ] || git clone -b develop https://github.com/theforeman/foreman.git
	popd
}

function deploy_foreman17_start(){
	cd $ghdir/lzap/bin-public
	./virt-spawn --force -n $1 -- "FOREMAN_REPO=releases/1.7"
	local hostname="$1.local.lan"
	local ip=`sudo virsh net-dumpxml --network default | xmllint --xpath "string(/network/ip/dhcp/host[@name='${hostname}']/@ip)" -`
	cp /etc/hosts /tmp
	sudo sh -c "grep -v $hostname /tmp/hosts > /etc/hosts"
	echo "$ip $hostname"
	sudo sh -c "echo '$ip $hostname' >> /etc/hosts"
	while ! ping -c 1 $hostname; do
		sleep 10
	done
}

function deploy_foreman17_wait(){
	sed -i 's/^'$1',.*$//g' ~/.ssh/known_hosts
	while ! ssh -o StrictHostKeyChecking=no root@$1 'true'; do
		sleep 10
	done
	ssh root@$1 '
		( tail -f virt-sysprep-firstboot.log & echo $! >pid) | \
			while read line; do
				echo $line
				if echo $line | grep "collect important logs"; then
					echo "foreman is ready"
					kill $(<pid)
				fi
			done
		'
}

function patch_foreman17(){
	local server=$1
	pushd $ghdir/theforeman/foreman/
	git format-patch f8a56f5bd809305080e4^..f8a56f5bd809305080e4
	scp $ghdir/theforeman/foreman/0001* root@$server:
	popd
	ssh root@$server '
		rpm -q patch || yum install patch -y \
		&& cd ~foreman \
		&& patch -p1 < ~/0001* | grep succeeded
		'
}

function deploy_rubygem_openscap(){
	local server=$1
	ssh root@$server '
		cd /etc/yum.repos.d/ \
		&& wget https://copr.fedoraproject.org/coprs/isimluk/OpenSCAP/repo/epel-6/isimluk-OpenSCAP-epel-6.repo \
		&& yum install openscap-utils ruby193-rubygem-openscap -y \
		'
}

function build_and_deploy(){
	local project=$1
	local server=$2
	ssh root@$server '
		   cd '$project' \
		&& rm -rf ~/rpmbuild \
		&& yum-builddep -y rubygem-'$project'.spec \
		&& rpmbuild  --define "_sourcedir `pwd`" -ba rubygem-'$project'.spec \
		&& rpm -Uvh --force ~/rpmbuild/RPMS/noarch/rubygem-'$project'-*.noarch.rpm
		'
}

function build_and_deploy_scl(){
	local project=$1
	local server=$2
	ssh root@$server '
                   (rpm -q scl-utils || yum install -y scl-utils) \
                ;  (rpm -q scl-utils-build || yum install -y scl-utils scl-utils-build) \
                ;  (rpm -q ruby193-rubygems-devel || yum install -y ruby193-rubygems-devel) \
		&& cd '$project' \
		&& rm -rf ~/rpmbuild \
		&& rpmbuild  --define "_sourcedir `pwd`" --define "scl ruby193" -ba rubygem-'${project}'.spec \
		&& rpm -Uvh --force ~/rpmbuild/RPMS/noarch/ruby193-rubygem-'$project'*.noarch.rpm
		'
}

function copy_gem_to(){
	local project=$1
	local server=$2
	gem build $project.gemspec
	ssh root@$server 'mkdir '$project
	scp -r $project-*.gem root@$server:$project/
	scp -r $ghdir/theforeman/foreman-packaging/rubygem-$project/rubygem-${project}.spec root@$server:$project/
}

function deploy_scaptimony(){
	local project=scaptimony
	local server=$1
	pushd $ghdir/openscap/$project
	copy_gem_to $project $server
	build_and_deploy_scl $project $server
	popd
}

function workaround_packaging_foreman_openscap_032(){
	pushd ../../theforeman/foreman-packaging
	git remote | grep -q isimluk || git remote add isimluk https://github.com/isimluk/foreman-packaging
	git fetch isimluk
	git checkout isimluk/foreman_openscap
	popd
}

function workaround_packaging_foreman_openscap_032_end(){
	pushd ../../theforeman/foreman-packaging
	git checkout rpm/develop
	popd
}

function deploy_foreman_openscap(){
	local project=foreman_openscap
	local server=$1
	pushd $ghdir/openscap/$project
	workaround_packaging_foreman_openscap_032
	copy_gem_to $project $server
	ssh root@$server '
		   (rpm -q foreman-assets || yum install -y foreman-assets) \
		&& yum remove ruby193-rubygem-foreman_openscap -y
		'
	build_and_deploy_scl $project $server
	workaround_packaging_foreman_openscap_032_end
	ssh root@$server '
		service foreman restart
		'
	popd
}

function workaround_authentication_for_17(){
	git checkout maint-foreman17
}


function deploy_smart_proxy_openscap(){
	local project=smart_proxy_openscap
	local server=$1
	pushd $ghdir/openscap/$project
	workaround_authentication_for_17
	copy_gem_to $project $server
	ssh root@$server '
		   (rpm -q ruby193-rubygems-devel && yum remove -y ruby193-rubygems-devel)
		'
	build_and_deploy $project $server
	ssh root@$server '
		service foreman-proxy restart
		'
	popd
}

function deploy_foreman_scap_client(){
	local project=foreman_scap_client
	local server=$1
	pushd $ghdir/openscap/$project
	copy_gem_to $project $server
	build_and_deploy $project $server
	popd
}

function workaround_packaging_513(){
	# https://github.com/theforeman/foreman-packaging/pull/513
	pushd ../../theforeman/foreman-packaging
	git remote | grep -q isimluk || git remote add isimluk https://github.com/isimluk/foreman-packaging
	git fetch isimluk
	git checkout isimluk/puppet-foreman_scap_client
	popd
}

function deploy_puppet_foreman_scap_client(){
	local project="puppet-foreman_scap_client"
	local server=$1
	pushd $ghdir/openscap/$project
	rm -rf ./pkg/*
	puppet module build .
	ssh root@$server 'mkdir -p '$project
	scp -r ./pkg/*.tar.gz root@$server:$project/
	workaround_packaging_513
	scp -r $ghdir/theforeman/foreman-packaging/$project/${project}.spec root@$server:$project/
	ssh root@$server '
		   cd '$project' \
		&& rm -rf ~/rpmbuild \
		&& yum-builddep -y '$project'.spec \
		&& rpmbuild  --define "_sourcedir `pwd`" -ba '$project'.spec \
		&& (rpm -q puppetlabs-stdlib) || yum install -y puppetlabs-stdlib \
		&& rpm -Uvh --force ~/rpmbuild/RPMS/noarch/'$project'-*.noarch.rpm
		'
	popd
}

function json_path(){
	local file=$1
	local question="$2"
	cat $file | python -c 'import json,sys; x = json.load(sys.stdin); print x'"$question"''
}

function import_puppet_foreman_scap_client(){
	local server=$1
	local json=`mktemp`
	curl -k -u admin:admin -H 'Accept: version=2,application/json' https://$server/api/smart_proxies > $json
	proxy_id=`json_path $json '["results"][0]["id"]'`
	curl -k -u admin:admin -H "Accept: version=2,application/json" -H "Content-Type: application/json" -X POST \
		https://foreman17test.local.lan/api/v2/smart_proxies/$proxy_id/import_puppetclasses > $json
	json_path $json '["results"][0]["new_puppetclasses"]' | grep foreman_scap_client
	json_path $json '["results"][1]["new_puppetclasses"]' | grep foreman_scap_client
}

function test_foreman_openscap(){
	local server=$1
	test_ensure_no_scap_content $server
	test_ensure_no_policy $server
}

function test_ensure_no_scap_content(){
	local server=$1
	local json=`mktemp`
	curl -k -u admin:admin -H "Accept: version=2,application/json" https://$server/api/policies > $json
	grep '"total": 0' $json
	grep '"subtotal": 0' $json
	rm $json
}

function test_ensure_no_policy(){
	local server=$1
	local json=`mktemp`
	curl -k -u admin:admin -H "Accept: version=2,application/json" https://$server/api/scap_contents > $json
	grep '"total": 0' $json
	grep '"subtotal": 0' $json
	rm $json
}
