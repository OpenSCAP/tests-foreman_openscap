#!/bin/bash

function local_requires(){
	for pkg in virt-install libguestfs-tools-c rubygems puppet fortune-mod; do
		rpm -q --quiet $pkg || sudo yum install -y $pkg
	done
	sudo service libvirtd start
	sudo mkdir -p /root/.cache/virt-builder
	clone_foreman_spawn
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
	[ -d scaptimony ] || git clone https://github.com/OpenSCAP/scaptimony.git
	[ -d foreman_openscap ] || git clone https://github.com/OpenSCAP/foreman_openscap.git
	[ -d smart_proxy_openscap ] || git clone https://github.com/OpenSCAP/smart_proxy_openscap.git
	[ -d foreman_scap_client ] || git clone https://github.com/OpenSCAP/foreman_scap_client.git
	[ -d puppet-foreman_scap_client ] || git clone https://github.com/OpenSCAP/puppet-foreman_scap_client.git
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
	pushd $ghdir/theforeman/foreman/
	git format-patch f8a56f5bd809305080e4^..f8a56f5bd809305080e4
	scp $ghdir/theforeman/foreman/0001* root@$host:
	popd
	ssh root@$host '
		rpm -q patch || yum install patch -y \
		&& cd ~foreman \
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

function deploy_foreman_openscap(){
	local project=foreman_openscap
	local server=$1
	pushd $ghdir/openscap/$project
	copy_gem_to $project $server
	ssh root@$server '
		   (rpm -q foreman-assets || yum install -y foreman-assets) \
		&& yum remove ruby193-rubygem-foreman_openscap -y
		'
	build_and_deploy_scl $project $server
	ssh root@$server '
		service foreman restart
		'
	popd
}

function deploy_smart_proxy_openscap(){
	local project=smart_proxy_openscap
	local server=$1
	pushd $ghdir/openscap/$project
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

function deploy_puppet_foreman_scap_client(){
	local project="puppet-foreman_scap_client"
	local server=$1
	pushd $ghdir/openscap/$project
	puppet module build .
	ssh root@$server 'mkdir -p '$project
	scp -r $project-*.gem root@$server:$project/
	scp -r $ghdir/theforeman/foreman-packaging/rubygem-$project/rubygem-${project}.spec root@$server:$project/
	ssh root@$server '
		   cd '$project' \
		&& rm -rf ~/rpmbuild \
		&& yum-builddep -y '$project'.spec \
		&& rpmbuild  --define "_sourcedir `pwd`" -ba '$project'.spec \
		&& rpm -Uvh --force ~/rpmbuild/RPMS/noarch/'$project'-*.noarch.rpm
		'
	popd
}

