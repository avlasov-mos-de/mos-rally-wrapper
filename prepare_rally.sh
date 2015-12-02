#!/bin/bash

set -e
#===================================================================
echo "Initializing rally database"
sleep 2

rally-manage db recreate

###==================================================================
source openrc

echo "${OS_PUBLIC_IP} $(echo ${OS_AUTH_URL} | sed 's/https:\/\///;s|:.*||')" >> /etc/hosts

echo "Please use operc to answer following questions"
echo "Please notice that openrc has been predownloaded from controller and URL has been changed to public which will be default value in the dialog below"

read -e -p "Enter auth_url, example http://example.net:5000/v2.0/ : " -i "${OS_AUTH_URL}" auth_url
read -e -p "Region_name: " -i "${OS_REGION_NAME}" region_name
read -e -p "Endpoint_type(one of the 'public' 'internal' 'admin'): " -i "public" endpoint_type
read -e -p "Admin user name: " -i "${OS_USERNAME}" admin_username
read -e -p "Admin user password: " -i "${OS_PASSWORD}" admin_password
read -e -p "Admin tenant name: " -i "${OS_TENANT_NAME}" admin_tenant_name

export auth_url
export region_name
export endpoint_type
export admin_username
export admin_password
export admin_tenant_name


echo "Do you wish to use for tests existing user another then admin?"
echo "i.e. You have read-only LDAP backend"
select yn in "Yes" "No"; do
    case $yn in
        Yes )
              existing_users=true
              cloud_template_filename="existing_cloud_precreated-user.json.tmpl"
              tasks_template_filename="MOS-benchmark-tasks_precreated-user.yaml.tmpl"
              echo "Please specify user details"
              read -p "Usern name user #$i: " user_name
              read -p "Password for user #$i: " user_pass
              read -p "Tenant for user #$i: " user_tenant

              export cloud_template_filename
              export tasks_template_filename
              export user_name
              export user_pass
              export user_tenant
              break
              ;;
        No )
              existing_users=false
              cloud_template_filename="existing_cloud_admin-user.json.tmpl"
              tasks_template_filename="MOS-benchmark-tasks_admin-user.yaml.tmpl"

              export cloud_template_filename
              export tasks_template_filename
              export user_name=""
              export user_pass=""
              export user_tenant=""
              break;;
    esac
done

echo "Creating config file which will be used to add cloud to rally db"
sleep 2


python - << EOF | tee existing-cloud.json > /dev/null
import jinja2; import os; dir=os.getcwd()+"/templates/"
env=jinja2.Environment(loader=jinja2.FileSystemLoader(dir))
template_name=os.environ["cloud_template_filename"]
template=env.get_template(template_name)
print template.render(auth_url=os.environ["auth_url"], region_name=os.environ["region_name"], endpoint_type=os.environ["endpoint_type"], admin_username=os.environ["admin_username"], admin_password=os.environ["admin_password"], admin_tenant_name=os.environ["admin_tenant_name"], user_name=os.environ["user_name"], user_pass=os.environ["user_pass"], user_tenant=os.environ["user_tenant"])
EOF



###================================================================

echo "We are about to add cloud you are to test. Please give name to your cloud"
read -e -p "Cloud name: " -i "our_cloud" cloud_name

rally deployment create --file existing-cloud.json --name ${cloud_name}


echo "Now we are checking that everything works"
echo "You can use 'rally deployment list' and 'rally deployment check' commands to do the same"

sleep 3

rally deployment list
rally deployment check

###================================================================

source openrc
vcpu_total=`nova --insecure hypervisor-stats |grep "vcpus " |grep -v vcpus_used | awk '{print $4}'`
vcpu_used=`nova --insecure hypervisor-stats |grep vcpus_used | awk '{print $4}'`

vcpu_count=$(( $vcpu_total-$vcpu_used ))

echo "Now we are creating task scenario file"
echo "Please answer following qestions"

read -e -p "Image name for benchmarks: " -i "TestVM" image_name
read -e -p "Flavor name you would like to use : " -i "m1.tiny" flavor_name
read -e -p "How many instances you would like to spawn during benchmarking. By default we use number of unused VCPUs in your cloud : " -i "$vcpu_count" instance_count
read -e -p "Volume size to use for benchamrking in GB: " -i "100" volume_size
read -e -p "How many volumes you would like tocreate : " -i "10" volume_count


export instance_count

sqrt_of_inst_count=`python -c 'import math; import os; vcpu_c=float(os.environ["instance_count"]); print math.trunc(math.sqrt(vcpu_c))'`


cat > args.yaml << EOF
---
  image_name: "$image_name"
  flavor_name: "$flavor_name"
  instance_count: "$instance_count"
  volume_size: "$volume_size"
  volume_count: "$volume_count"
  sqrt_of_inst_count: "$sqrt_of_inst_count"
EOF

cat ${PWD}/templates/${tasks_template_filename} | tee MOS-benchmark-tasks.yaml > /dev/null


echo "We are ready to ran task itself"
echo "Executing 'rally task start MOS-benchmark-tasks.yaml --task-args-file args.yaml'"

rally task start MOS-benchmark-tasks.yaml --task-args-file args.yaml
