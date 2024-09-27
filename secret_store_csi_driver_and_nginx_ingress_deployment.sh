##################################################################################
#
#
# Created: 18 Sep 2024
# Description : To install required EKS components
# Authors : Muthuselvam Annamalai, Suresh Selvam
#
#
##################################################################################

source aws_eksctl_cli.env

cd secrets-store-csi-driver-main/
pwd
echo "Installing secrets-store-csi-driver..."
## Deploy the Secrets Store CSI Driver in the "kube-system" namespace
{
    kubectl apply -f deploy/rbac-secretproviderclass.yaml
    kubectl apply -f deploy/csidriver.yaml
    kubectl apply -f deploy/secrets-store.csi.x-k8s.io_secretproviderclasses.yaml
    kubectl apply -f deploy/secrets-store.csi.x-k8s.io_secretproviderclasspodstatuses.yaml
    kubectl apply -f deploy/secrets-store-csi-driver.yaml

    # If using the driver to sync secrets-store content as Kubernetes Secrets, deploy the additional RBAC permissions
    # required to enable this feature
    kubectl apply -f deploy/rbac-secretprovidersyncing.yaml

    # If using the secret rotation feature, deploy the additional RBAC permissions
    # required to enable this feature
    kubectl apply -f deploy/rbac-secretproviderrotation.yaml

    # If using the CSI Driver token requests feature (https://kubernetes-csi.github.io/docs/token-requests.html) to use
    # pod/workload identity to request a token and use with providers
    kubectl apply -f deploy/rbac-secretprovidertokenrequest.yaml

    # [OPTIONAL] To deploy driver on windows nodes
    kubectl apply -f deploy/secrets-store-csi-driver-windows.yaml

    ## Installing the AWS Provider
    kubectl apply -f deploy/aws-provider-installer.yaml
}

### Deploying cluster-autoscaler service to enable cluster auto scaling for scaling up and scaling down the Nodes
cd ..
cd cluster-autoscaler/
pwd
sed -i 's/{CLUSTER_NAME}/'"${CLUSTER_NAME}"'/g' cluster-autoscaler-autodiscover.yaml
## Installing cluster-autoscaler autodiscover 
echo "Installing cluster autoscaler for node autoscaling"
kubectl apply -f cluster-autoscaler-autodiscover.yaml

sleep 30

### Deploying metrics-server service to enable metrics collection at pod and node level 
### to allow Horizontal Pod Autoscaler utilize this metrics to implement HPA
cd ..
cd metrics-server/
pwd
echo "installing metrics-server for pod autoscaling"
kubectl apply -f components.yaml

sleep 30

cd ..
cd nginx-ingress/
pwd
echo "Installing nginx ingress controller..."
## Deploy the nginx ingress controller in the nginube-system namespace "nginx-ingress"
{
kubectl apply -f deployments/common/ns-and-sa.yaml
kubectl apply -f deployments/rbac/rbac.yaml

kubectl apply -f examples/shared-examples/default-server-secret/default-server-secret.yaml
kubectl apply -f deployments/common/nginx-config.yaml
kubectl apply -f deployments/common/ingress-class.yaml

kubectl apply -f config/crd/bases/k8s.nginx.org_virtualservers.yaml
kubectl apply -f config/crd/bases/k8s.nginx.org_virtualserverroutes.yaml
kubectl apply -f config/crd/bases/k8s.nginx.org_transportservers.yaml
kubectl apply -f config/crd/bases/k8s.nginx.org_policies.yaml
kubectl apply -f config/crd/bases/k8s.nginx.org_globalconfigurations.yaml

kubectl apply -f deployments/deployment/nginx-ingress.yaml
}


## Edit Public Subnets ID's of VPC in file before executing below commands - needs to be executed in tenant folder
kubectl apply -f deployments/service/loadbalancer.yaml