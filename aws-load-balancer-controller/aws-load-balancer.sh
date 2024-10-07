##################################################################################
#
#
# Created: 18 Sep 2024
# Description : For Installing AWS LoadBalancer Controller
# Authors : Muthuselvam Annamalai, Suresh Selvam
#
#
##################################################################################

### Source the environment variables
source ../aws_eksctl_cli.env

EKS_LOADBALANCERCONTROLLER_ROLE=AmazonEKSLoadBalancerControllerRole
IAM_LOADBALANCERCONTROLLER_POLICY=AWSLoadBalancerControllerIAMPolicy
AWS_LOAD_BALANCER_CONTROLLER_SERVICE_ACCOUNT=aws-load-balancer-controller

ALB_CONTROLLER_FILE_VERSION=v2_7_2

VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster".resourcesVpcConfig.vpcId \
    --output text --region $REGION --profile ${PROFILE})

### Create an IAM policy named AWSLoadBalancerControllerIAMPolicy.
iam_albcontroller_policy=$(aws iam list-policies --profile ${PROFILE} | grep $IAM_LOADBALANCERCONTROLLER_POLICY) || true
if [[ -z "$iam_albcontroller_policy" ]]; then
	echo "***** Policy 'AWSLoadBalancerControllerIAMPolicy' not found, creating one *****"
	aws iam create-policy \
		--policy-name $IAM_LOADBALANCERCONTROLLER_POLICY \
		--policy-document file://./iam_policy.json \
		--tags '[{"Key":"Product","Value":"Hawkeye"},{"Key":"OWNER", "Value":"hawkEye"},{"Key":"ClusterName", "Value":"hawkeye-dev"},{"Key":"CreatedBy", "Value":"CloudOps_IAC"}]' \
		--profile ${PROFILE}
	echo "***** Policy 'AWSLoadBalancerControllerIAMPolicy' has been created *****"
else
	echo "policy 'AWSLoadBalancerControllerIAMPolicy' exists"
fi

### create load-balancer-role-trust-policy
echo "create load-balancer-role-trust-policy (AWS CLI)"
oidc_id=$(aws eks describe-cluster --name $CLUSTER_NAME \
	  --query "cluster.identity.oidc.issuer" --region $REGION --output text --profile ${PROFILE} | cut -d '/' -f 5)
oidc_provider_id=$(aws iam list-open-id-connect-providers --profile ${PROFILE} | grep $oidc_id | cut -d "/" -f4)

### To remove the last double quote char in oidc_provider_id
oidc_provider_id=$(echo "${oidc_provider_id//\"}")
echo "oidc_provider_id :  $oidc_provider_id"
cat >load-balancer-role-trust-policy.json <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Principal": {
				"Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/oidc.eks.$REGION.amazonaws.com/id/$oidc_provider_id"
			},
			"Action": "sts:AssumeRoleWithWebIdentity",
			"Condition": {
				"StringEquals": {
					"oidc.eks.$REGION.amazonaws.com/id/$oidc_provider_id:aud": "sts.amazonaws.com",
					"oidc.eks.$REGION.amazonaws.com/id/$oidc_provider_id:sub": "system:serviceaccount:kube-system:$AWS_LOAD_BALANCER_CONTROLLER_SERVICE_ACCOUNT"
				}
			}
		}
	]
}
EOF
#cat load-balancer-role-trust-policy.json
echo "created load-balancer-role-trust-policy"


### create IAM role AmazonEKSLoadBalancerControllerRole
iam_albcontroller_role=$(aws iam list-roles --profile ${PROFILE} | grep $EKS_LOADBALANCERCONTROLLER_ROLE) || true
#iam_albcontroller_role=$(aws iam get-role --role-name $EKS_LOADBALANCERCONTROLLER_ROLE)
if [[ -z "$iam_albcontroller_role" ]]; then
	echo "***** Role 'AmazonEKSLoadBalancerControllerRole' not found, creating one *****"
	aws iam create-role \
		--role-name $EKS_LOADBALANCERCONTROLLER_ROLE \
		--assume-role-policy-document file://./load-balancer-role-trust-policy.json \
		--tags '[{"Key":"Product","Value":"Hawkeye"},{"Key":"OWNER", "Value":"hawkEye"},{"Key":"ClusterName", "Value":"hawkeye-dev"},{"Key":"CreatedBy", "Value":"CloudOps_IAC"}]' \
		--profile ${PROFILE}
	echo "***** Role 'AmazonEKSLoadBalancerControllerRole' has been created *****"
else
	echo "iam role AmazonEKSLoadBalancerControllerRole exists"
fi
echo "policy_arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/$IAM_LOADBALANCERCONTROLLER_POLICY"

### Attach AWSLoadBalancerControllerIAMPolicy to IAM roles
echo "***** Attaching 'load-balancer-role-trust-policy' with IAM role AmazonEKSLoadBalancerControllerRole *****"
aws iam attach-role-policy \
--policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/$IAM_LOADBALANCERCONTROLLER_POLICY" \
--role-name $EKS_LOADBALANCERCONTROLLER_ROLE \
--profile ${PROFILE}
		
echo "***** Attached 'load-balancer-role-trust-policy' with IAM role AmazonEKSLoadBalancerControllerRole *****"

### Install Cert-manager 
kubectl apply --validate=false -f ./cert-manager.yaml

echo "***** Waiting for cert-manager/cert-manager-webhook to come up online *****"
sleep 120
echo "***** cert-manager/cert-manager-webhook service is up and running *****"
sed -i.bak "s|{CLUSTER_NAME}|${CLUSTER_NAME}|g" ./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
sed -i.bak "s|{VPC_ID}|${VPC_ID}|g" ./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
sed -i.bak "s|{AWS_REGION}|${REGION}|g" ./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
sed -i.bak "s|{AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" ./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
sed -i.bak "s|{EKS_LOADBALANCERCONTROLLER_ROLE}|${EKS_LOADBALANCERCONTROLLER_ROLE}|g" \
	./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
kubectl apply --validate=false -f ./${ALB_CONTROLLER_FILE_VERSION}_full.yaml
kubectl apply --validate=false -f ./${ALB_CONTROLLER_FILE_VERSION}_ingclass.yaml