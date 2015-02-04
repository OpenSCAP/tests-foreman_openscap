Scripts to build OpenSCAP enabled Foreman 1.7

 * Downloads Centos-6 image
 * creates new VM based on that Centos image
 * installs foreman-1.7 into the VM
 * installs all the openscap packages into VM
   * using various hack to deliver functional environment
 * all the packages are installed using rpm (avoiding gem head scratching)
