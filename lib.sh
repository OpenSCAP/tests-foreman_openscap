#!/bin/bash

function local_requires(){
	for pkg in virt-install libguestfs-tools-c rubygems puppet; do
		rpm -q --quiet $pkg || sudo yum install -y $pkg
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
	ssh root@$server 'mkdir '$project
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

