# mos-rally-wrapper

#Prerequisites:

Fuel master node should be able to reach Public VIP
Download archive with two scripts and extract it

#Further steps

Install git, clone repo, change to mos-rally-wrapper directory and execute script prepare_rally_container.sh 

  yum -y install git
  git clone https://github.com/avlasov-mos-de/mos-rally-wrapper.git
  cd mos-rally-wrapper/
  ./prepare_rally_container.sh

This script will 
- create directory rally_home which will be mounted inside rally container to /home/rally
- get openrc file from controller node and make changes in order to use Public nedpoint
- try to change keystone endpoint so that it use PublicIP for adminurl
- place second script prepare_rally.sh to ~/rally_home so that you were able to run it later inside container
- pull rally docker image and start container 
As result you end up inside container. 

#So follow next steps

As you're now inside container. Make sure your location is /home/rally

cd /home/rally/

Execute prepare_rally.sh

This script will 
- recreate rally database 
- use opernc and ask you questions regarding connection to your cloud(url, region, admin user credentials, additional    users credentials, etc)
- create config file for adding cloud to rally DB and add it
- suggest values for benchmarking(you can edit them).
- write files with tasks for benchmarking
run benchmarking itself
Afterwards you’re able to work inside container.

#notes

During setup docker container will be created. It has name 'rally-MOS-benchmarking'
So if you press ctrl+D when you inside container you can just login agein with 'dockerctl shell rally-MOS-benchmarking'

#cleanup

clenup.sh will stop and remove 'rally-MOS-benchmarking' container as well as ~/rally_home directory

