# https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-prepare-cluster?tabs=ubuntu
# Enable auto export
set -a

ssh-keygen -t ed25519 -C "iot" -f ~/id_rsa -N ""
ssh_public_key=$(cat ~/id_rsa.pub)

# All the variables for the deployment
subscription_name="workload1-production-online"
resource_group_name="rg-azure-iot-operations"
location="northeurope"
workspace_name="log-iot"

vnet_name="vnet-iot"
subnet_vm_name="snet-vm"

vm_name="vm"
vm_username="azureuser"

nsg_name="nsg-vm"
nsg_rule_ssh_name="ssh-rule"
nsg_rule_myip_name="myip-rule"
nsg_rule_deny_name="deny-rule"

# Create resource group
az group create -l $location -n $resource_group_name -o table

az network nsg create \
  --resource-group $resource_group_name \
  --name $nsg_name

my_ip=$(curl --no-progress-meter https://myip.jannemattila.com)
echo $my_ip

az network nsg rule create \
  --resource-group $resource_group_name \
  --nsg-name $nsg_name \
  --name $nsg_rule_ssh_name \
  --protocol '*' \
  --direction inbound \
  --source-address-prefix $my_ip \
  --source-port-range '*' \
  --destination-address-prefix '*' \
  --destination-port-range '22' \
  --access allow \
  --priority 100

az network nsg rule create \
  --resource-group $resource_group_name \
  --nsg-name $nsg_name \
  --name $nsg_rule_myip_name \
  --protocol '*' \
  --direction outbound \
  --source-address-prefix '*' \
  --source-port-range '*' \
  --destination-address-prefix $my_ip \
  --destination-port-range '*' \
  --access allow \
  --priority 100

vnet_id=$(az network vnet create -g $resource_group_name --name $vnet_name \
  --address-prefix 10.0.0.0/8 \
  --query newVNet.id -o tsv)
echo $vnet_id

subnet_vm_id=$(az network vnet subnet create -g $resource_group_name --vnet-name $vnet_name \
  --name $subnet_vm_name --address-prefixes 10.4.0.0/24 \
  --network-security-group $nsg_name \
  --query id -o tsv)
echo $subnet_vm_id

vm_json=$(az vm create \
  --resource-group $resource_group_name  \
  --name $vm_name \
  --image "Canonical:ubuntu-24_04-lts:server:latest" \
  --size Standard_B8as_v2 \
  --admin-username $vm_username \
  --ssh-key-type Ed25519 \
  --ssh-key-value "$ssh_public_key" \
  --vnet-name $vnet_name \
  --subnet $subnet_vm_name \
  --accelerated-networking true \
  --nsg "" \
  --public-ip-sku Standard \
  -o json)

vm_public_ip_address=$(echo $vm_json | jq -r .publicIpAddress)
echo $vm_public_ip_address
vm_public_ip_address="20.91.141.156"

# Display variables
ssh $vm_username@$vm_public_ip_address -i ~/id_rsa

################################################
# ___           _     _       __     ____  __                                                                                                                 
# _ _|_ __  ___(_) __| | ___  \ \   / /  \/  |
# | || '_ \/ __| |/ _` |/ _ \  \ \ / /| |\/| |
# | || | | \__ \ | (_| |  __/   \ V / | |  | |
# ___|_| |_|___/_|\__,_|\___|    \_/  |_|  |_|
# https://docs.k3s.io/quick-start
################################################

curl -sfL https://get.k3s.io | sh -

# curl -sfL https://get.k3s.io | K3S_URL=https://myserver:6443 K3S_TOKEN=mynodetoken sh -

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

mkdir ~/.kube
sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
chmod  0600 ~/.kube/config
export KUBECONFIG=~/.kube/config
#switch to k3s context
kubectl config use-context default
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf

sudo sysctl -p

echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf

sudo sysctl -p

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az login

# Prepare extensions and providers
az extension add --upgrade --name connectedk8s
az extension add --upgrade --name azure-iot-ops

az provider register -n "Microsoft.ExtendedLocation"
az provider register -n "Microsoft.Kubernetes"
az provider register -n "Microsoft.KubernetesConfiguration"
az provider register -n "Microsoft.IoTOperations"
az provider register -n "Microsoft.DeviceRegistry"
az provider register -n "Microsoft.SecretSyncController"

az connectedk8s connect \
  --name k3scluster \
  --resource-group rg-azure-iot-operations \
  --location northeurope \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --disable-auto-upgrade

issuerUrl=$(az connectedk8s show \
  --name k3scluster \
  --resource-group rg-azure-iot-operations \
  --query oidcIssuerProfile.issuerUrl \
  --output tsv)

sudo tee /etc/rancher/k3s/config.yaml > /dev/null << EOF
kube-apiserver-arg:
 - service-account-issuer=$issuerUrl
 - service-account-max-token-expiration=24h
EOF

sudo cat /etc/rancher/k3s/config.yaml

custom_location_object_id=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)

az connectedk8s enable-features \
  -n k3scluster \
  -g rg-azure-iot-operations \
  --custom-locations-oid $custom_location_object_id \
  --features cluster-connect custom-locations

sudo systemctl restart k3s

storage_account="iotopsstorage000010"
schema_registry="schemaregistry000010"
schema_registry_namespace="schemaregistry"

az storage account create --name $storage_account --location northeurope --resource-group rg-azure-iot-operations --enable-hierarchical-namespace
storage_id=$(az storage account show --name $storage_account -o tsv --query id)

az iot ops schema registry create --name $schema_registry --resource-group rg-azure-iot-operations --location northeurope --registry-namespace $schema_registry_namespace --sa-resource-id $storage_id
schema_registry_id=$(az iot ops schema registry show --name $schema_registry --resource-group rg-azure-iot-operations -o tsv --query id)

az iot ops init --cluster k3scluster --resource-group rg-azure-iot-operations

az iot ops create \
  --cluster k3scluster \
  --resource-group rg-azure-iot-operations \
  --name k3scluster-instance \
  --sr-resource-id $schema_registry_id \
  --broker-frontend-replicas 1 \
  --broker-frontend-workers 1 \
  --broker-backend-part 1 \
  --broker-backend-workers 1 \
  --broker-backend-rf 2 \
  --broker-mem-profile Low

az iot ops check

kubectl get pods -n azure-iot-operations

# Deploy OPC PLC simulator
# https://learn.microsoft.com/en-us/azure/iot-operations/end-to-end-tutorials/tutorial-add-assets
kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/opc-plc-deployment.yaml

kubectl get assetendpointprofile -n azure-iot-operations

kubectl get assets -n azure-iot-operations

kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml

kubectl exec --stdin --tty mqtt-client -n azure-iot-operations -- sh

mosquitto_sub --host aio-broker --port 18883 --topic "azure-iot-operations/data/#" -v --debug --cafile /var/run/certs/ca.crt -D CONNECT authentication-method 'K8S-SAT' -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)

exit
