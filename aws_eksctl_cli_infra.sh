#!/bin/bash

##################################################################################
#
#
# Created: 18 Sep 2024
# Description : To create infra required for UniSecure-Lite
# Authors : Muthuselvam Annamalai, Suresh Selvam
#
#
##################################################################################

### Source the environment variables
source aws_eksctl_cli.env

### References
### https://eksctl.io/usage/schema/#nodeGroups-tags
### https://eksctl.io/usage/iam-policies/
### https://eksctl.io/usage/iam-policies/
### https://eksctl.io/usage/launch-template-support/

### https://katharharshal1.medium.com/kubernetes-cluster-autoscaling-ca-using-aws-eks-4aab8c89f9a1
### https://aws.github.io/aws-eks-best-practices/cluster-autoscaling/

### Creating cluster with config file
cat > /tmp/eks_cluster_creation_input.yaml << EOF
accessConfig:
  authenticationMode: API_AND_CONFIG_MAP
  bootstrapClusterCreatorAdminPermissions: true
apiVersion: eksctl.io/v1alpha5
availabilityZones: [${CLUSTER_AVAILABILITY_ZONES}]
cloudWatch:
  clusterLogging: {}
iam:
  vpcResourceControllerPolicy: true
  withOIDC: true
  serviceAccounts:
  - metadata:
      name: ebs-csi-controller-sa
      namespace: kube-system
    wellKnownPolicies:
      ebsCSIController: true
  - metadata:
      name: efs-csi-controller-sa
      namespace: kube-system
    wellKnownPolicies:
      efsCSIController: true
  - metadata:
      name: cert-manager
      namespace: cert-manager
    wellKnownPolicies:
      certManager: true
  - metadata:
      name: cluster-autoscaler
      namespace: kube-system
      labels: {aws-usage: "cluster-ops"}
    wellKnownPolicies:
      autoScaler: true
  - metadata:
      name: autoscaler-service
      namespace: kube-system
    attachPolicy:
      Version: "2012-10-17"
      Statement:
      - Effect: Allow
        Action:
        - "autoscaling:SetDesiredCapacity"
        - "autoscaling:TerminateInstanceInAutoScalingGroup"
        Resource: "*"
        Condition: 
          StringEquals:
            aws:ResourceTag/k8s.io/cluster-autoscaler/enabled: 'true'
            aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}: owned
      - Effect: Allow
        Action:
        - "autoscaling:DescribeAutoScalingGroups"
        - "autoscaling:DescribeAutoScalingInstances"
        - "autoscaling:DescribeLaunchConfigurations"
        - "autoscaling:DescribeScalingActivities"
        - "autoscaling:DescribeTags"
        - "ec2:DescribeImages"
        - "ec2:DescribeInstanceTypes"
        - "ec2:DescribeLaunchTemplateVersions"
        - "ec2:GetInstanceTypesFromInstanceRequirements"
        - "eks:DescribeNodegroup"
        Resource: "*"
kind: ClusterConfig
kubernetesNetworkConfig:
  ipFamily: IPv4
  serviceIPv4CIDR: ${CLUSTER_SERVICE_CIDR}
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  tags: ${TAGS}
  version: "${CLUSTER_K8S_VERSION}"
privateCluster:
  enabled: false
  skipEndpointCreation: false
  additionalEndpointServices: ["autoscaling","s3"]
vpc:
  autoAllocateIPv6: false
  cidr: ${CLUSTER_VPC_CIDR}
  clusterEndpoints:
    privateAccess: false
    publicAccess: true
  manageSharedNodeSecurityGroupRules: true
  nat:
    gateway: HighlyAvailable # other options: Disable, Single (default)

addons:
  - name: vpc-cni
    version: latest
    attachPolicyARNs:
      - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-ebs-csi-driver
    version: latest
    wellKnownPolicies:      # add IAM and service account
      ebsCSIController: true
  - name: aws-efs-csi-driver
    version: latest
    wellKnownPolicies:      # add IAM and service account
      efsCSIController: true

nodeGroups: []
EOF

AWS_PROFILE=${PROFILE} eksctl create cluster --config-file /tmp/eks_cluster_creation_input.yaml \
    --without-nodegroup

## Retrieving the VPC ID from the EKS Cluster created in the previous step
CLUSTER_VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster".resourcesVpcConfig.vpcId \
    --output text --region $REGION --profile ${PROFILE})
    
### Creating a Secuirty Group to be attached to node groups to allow all traffic within VPC
cat > /tmp/eks_cluster_nodegroup_sg_creation_template.json << EOF
{
    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "CloudFormation template for security group",
    "Parameters": {
        "VpcId": {
            "Type": "String",
            "Description": "VpcId",
            "Default": "vpc-b19b4bda"
        },
        "VpcCIDR": {
            "Type": "String",
            "Description": "Vpc CIDR Range",
            "Default": "10.108.0.0/16"
        },
        "GroupName": {
            "Type": "String",
            "Description": "Security Group Name",
            "Default": "VPC-CIDR-Allow-All-Traffic"
        }       
    },
    "Resources": {
        "eksclusterSG": {
            "Type": "AWS::EC2::SecurityGroup",
            "Properties": {
                "GroupDescription": "A Security Group to allow all traffic within VPC",
                "GroupName" : {
                    "Ref": "GroupName"
                },
                "VpcId": {
                    "Ref": "VpcId"
                },
                "Tags": [
                    { 
                        "Key": "Name", 
                        "Value": "eksclusterSG" 
                    },
                    {
                        "Key": "Environment",
                        "Value": "${ENVIRONMENT}"
                    },
                    {
                        "Key": "Product",
                        "Value": "${PRODUCT}"
                    },
                    {
                        "Key": "CreatedBy",
                        "Value": "${CREATEDBY}"
                    },
                    {
                        "Key": "Owner",
                        "Value": "${OWNER}"
                    }
                ]
            }
        },
        "IngressRule": {
            "Type": "AWS::EC2::SecurityGroupIngress",
            "Properties": {
                "GroupId": {
                    "Ref": "eksclusterSG"
                },
                "IpProtocol": "tcp",
                "FromPort": 443,
                "ToPort": 443,
                "CidrIp": "0.0.0.0/0"
            }
        },
        "IngressRule2": {
            "Type": "AWS::EC2::SecurityGroupIngress",
            "Properties": {
                "GroupId": {
                    "Ref": "eksclusterSG"
                },
                "IpProtocol": "tcp",
                "FromPort": 0,
                "ToPort": 65535,
                "CidrIp": {
                    "Ref": "VpcCIDR"
                }
            }
        },
        "EgressRule": {
            "Type": "AWS::EC2::SecurityGroupEgress",
            "Properties": {
                "GroupId": {
                    "Ref": "eksclusterSG"
                },
                "IpProtocol": "tcp",
                "FromPort": 443,
                "ToPort": 443,
                "CidrIp": "0.0.0.0/0"
            }
        }
    },
    "Outputs": {
        "SecurityGroupId": {
            "Description": "Security Group Id",
            "Value": {
                "Fn::GetAtt": [
                    "eksclusterSG",
                    "GroupId"
                ]
            }
        },
        "VpcId": {
            "Description": "VpcId in Which SG is there",
            "Value": {
                "Fn::GetAtt": [
                    "eksclusterSG",
                    "GroupId"
                ]
            },
            "Export" : { "Name" : {"Fn::Sub": "${AWS::StackName}-NGSecurityGroupID" }}          
        }
    }
}
EOF

cat > /tmp/eks-cluster-nodegroup-sg-creation-for-unisecure-lite-params.json << EOF
[
        {
            "ParameterKey": "VpcId",
            "ParameterValue": "${CLUSTER_VPC_ID}"
        },
        {
            "ParameterKey": "VpcCIDR",
            "ParameterValue": "${CLUSTER_VPC_CIDR}"
        },
        {
            "ParameterKey": "GroupName",
            "ParameterValue": "${NODE_ADDITIONAL_SECURITY_GROUPS}"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name eks-cluster-nodegroup-sg-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/eks_cluster_nodegroup_sg_creation_template.json \
    --parameters file:///tmp/eks-cluster-nodegroup-sg-creation-for-unisecure-lite-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}

### We are waiting for the cloud formation script to complete the resource creation as We need the Resource Detaisl to proceed further
aws cloudformation wait stack-create-complete \
    --stack-name eks-cluster-nodegroup-sg-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --profile ${PROFILE}

## Retrieving the Security Group ID created from the above stack
CLUSTER_NODEGROUP_SG=$(aws ec2 describe-security-groups \
    --filters Name=tag:Name,Values=eksclusterSG Name=vpc-id,Values=${CLUSTER_VPC_ID} \
    --query "SecurityGroups[*].[GroupId]" \
    --output text --profile ${PROFILE})

### Creating nodegroups (using Managed Nodes) with config file
cat > /tmp/eks_nodegroup_creation_input.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  tags: ${TAGS}
  version: "${CLUSTER_K8S_VERSION}"

managedNodeGroups:
  - name: ${NODE_GROUP_NAME1}
    amiFamily: ${NODE_AMI_FAMILY}
    availabilityZones: [${NODE_ZONES}]
    desiredCapacity: ${NODE_GROUP_NAME1_NODES}
    disableIMDSv1: true
    disablePodIMDS: false
    instancePrefix: ${CLUSTER_NAME}
    instanceSelector: {}
    instanceType: ${NODE_GROUP_NAME1_NODE_TYPE}
    labels: ${NODE_GROUP_NAME1_LABELS}
    maxSize: ${NODE_GROUP_NAME1_NODES_MAX}
    minSize: ${NODE_GROUP_NAME1_NODES_MIN}
    privateNetworking: true
    ssh:
      allow: true
      publicKeyPath: ${SSH_PUBLIC_KEY}
    volumeSize: ${NODE_VOLUME_SIZE}
    volumeType: ${NODE_VOLUME_TYPE}
    ebsOptimized: true
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        appMesh: true
        appMeshPreview: true
        ebs: true
        fsx: true
        efs: true
        awsLoadBalancerController: true
        albIngress: true
        cloudWatch: true
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    securityGroups:
      attachIDs: [${CLUSTER_NODEGROUP_SG}]

  - name: ${NODE_GROUP_NAME2}
    amiFamily: ${NODE_AMI_FAMILY}
    availabilityZones: [${NODE_ZONES}]
    desiredCapacity: ${NODE_GROUP_NAME2_NODES}
    disableIMDSv1: true
    disablePodIMDS: false
    instancePrefix: ${CLUSTER_NAME}
    instanceSelector: {}
    instanceType: ${NODE_GROUP_NAME2_NODE_TYPE}
    labels: ${NODE_GROUP_NAME2_LABELS}
    maxSize: ${NODE_GROUP_NAME2_NODES_MAX}
    minSize: ${NODE_GROUP_NAME2_NODES_MIN}
    privateNetworking: true
    ssh:
      allow: true
      publicKeyPath: ${SSH_PUBLIC_KEY}
    volumeSize: ${NODE_VOLUME_SIZE}
    volumeType: ${NODE_VOLUME_TYPE}
    ebsOptimized: true
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        appMesh: true
        appMeshPreview: true
        ebs: true
        fsx: true
        efs: true
        awsLoadBalancerController: true
        albIngress: true
        cloudWatch: true
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    securityGroups:
      attachIDs: [${CLUSTER_NODEGROUP_SG}]
EOF

AWS_PROFILE=${PROFILE} eksctl create nodegroup --config-file /tmp/eks_nodegroup_creation_input.yaml

#TAGS="${TAGS:-"{\"CreatedBy\": \"${CREATEDBY}\",\"Product\": \"${PRODUCT}\",\"Owner\": \"${OWNER}\",\"Environment\": \"${ENVIRONMENT}\"}"}"

### https://community.esri.com/t5/arcgis-enterprise-in-the-cloud-questions/cloudformation-samples/td-p/1126942
### https://github.com/awsdocs/aws-cloudformation-user-guide/issues/1055

### Creating PostgreSQL RDS with cloud formation template file
### https://chankongching.wordpress.com/2015/12/30/devops-using-aws-cloudformation-to-create-postgresql-database/

## Retrieving the VPC ID from the EKS Cluster created in the previous step
CLUSTER_VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster".resourcesVpcConfig.vpcId \
    --output text --region $REGION --profile ${PROFILE})

## Retrieving the subnet IDs from the EKS Cluster created in the previous step
# CLUSTER_SUBNET_IDS_LIST=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
#     --query "cluster".resourcesVpcConfig.subnetIds \
#     --output text --region $REGION --profile ${PROFILE})

# CLUSTER_SUBNET_ID1=`echo $CLUSTER_SUBNET_IDS_LIST | awk '{print $(NF)}'`
# CLUSTER_SUBNET_ID2=`echo $CLUSTER_SUBNET_IDS_LIST | awk '{print $(NF-1)}'`

# CLUSTER_SUBNET_IDS=${CLUSTER_SUBNET_ID1},${CLUSTER_SUBNET_ID2}

CLUSTER_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filter Name=vpc-id,Values=${CLUSTER_VPC_ID} \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output json --region $REGION --profile ${PROFILE})

### <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< PostgreSQL - RDS Creation >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
##KmsKeyId - The ARN of the AWS KMS key that's used to encrypt the DB instance

# cat > /tmp/postgresql_rds_creation_template.json << EOF
# {
#     "AWSTemplateFormatVersion": "2010-09-09",
#     "Description": "AWS CloudFormation Template for PostgreSQL, template to create a highly-available, RDS DBInstance version 16.1 with alarming on important metrics that indicate the health of the database **WARNING**  ",
#     "Parameters": {
#         "VpcId": {
#             "Type": "String",
#             "Description": "VpcId of your existing Virtual Private Cloud(VPC)",
#             "Default": "${CLUSTER_VPC_ID}"
#         },
#         "Subnets": {
#             "Type": "CommaDelimitedList",
#             "Description": "The list of SubnetIds,for at least two Availability Zones in the region",
#             "Default": "subnet-20r232"
#         },
#         "DBIdentifier": {
#             "Type": "String",
#             "Description": "The identifier of this postgresql database",
#             "Default": "${POSTGRESSQL_RDS_NAME}"
#         },
#         "MyDBName": {
#             "Default": "MyDatabase",
#             "Description": "The database name",
#             "Type": "String",
#             "MinLength": "1",
#             "MaxLength": "64",
#             "AllowedPattern": "[a-zA-Z][a-zA-Z0-9]*",
#             "ConstraintDescription": "must begin with a letter and contain only alphanumeric characters."
#         },
#         "DBUser": {
#             "Description": "The database admin account username",
#             "Type": "String",
#             "MinLength": "1",
#             "MaxLength": "16",
#             "AllowedPattern": "[a-zA-Z][a-zA-Z0-9]*",
#             "ConstraintDescription": "must begin with a letter and contain only alphanumeric characters.",
#             "Default": "postgres"
#         },
#         "DBPassword": {
#             "NoEcho": "true",
#             "Description": "The database admin account password",
#             "Type": "String",
#             "MinLength": "8",
#             "MaxLength": "41",
#             "AllowedPattern": "[a-zA-Z0-9-_.!]*",
#             "ConstraintDescription": "must contain only alphanumeric characters."
#         },
#         "DBEngineVersion": {
#             "Description": "Select Database Engine Version",
#             "Type": "String",
#             "Default": 16.1,
#             "AllowedValues": [
#                 11.16,
#                 12.11,
#                 13.7,
#                 14.3,
#                 16.1
#             ]
#         },
#         "DBParameterGroupName": {
#             "Type": "String",
#             "Description": "The DBParameterGroupName for this postgresql database",
#             "Default": "default.postgres16"
#         },
#         "DBAllocatedStorage": {
#             "Default": "50",
#             "Description": "The size of the database (Gb)",
#             "Type": "Number",
#             "MinValue": "5",
#             "MaxValue": "1024",
#             "ConstraintDescription": "must be between 5 and 1024Gb."
#         },
#         "MyDBInstanceClass": {
#             "Default": "db.m6gd.large",
#             "Description": "The database instance type",
#             "Type": "String",
#             "ConstraintDescription": "must select a valid database instance type."
#         },
#         "MultiAZDatabase": {
#             "Default": "true",
#             "Description": "Create a multi-AZ RDS database instance",
#             "Type": "String",
#             "AllowedValues": [
#                 "true",
#                 "false"
#             ],
#             "ConstraintDescription": "must be either true or false."
#         },
#         "BackupRetentionPeriod": {
#             "Default": "30",
#             "Description": "The period for which a backup should be retained.",
#             "Type": "Number"
#         },
#         "PreferredBackupWindow": {
#             "Default": "05:05-05:35",
#             "Description": "The daily time range in UTC during which you want to create automated backups.",
#             "Type": "String"
#         },
#         "PreferredMaintenanceWindow": {
#             "Default": "sun:06:06-sun:06:36",
#             "Description": "The weekly time range (in UTC) during which system maintenance can occur.",
#             "Type": "String"
#         }
#     },
#     "Resources": {
#         "MyDBSubnetGroup": {
#             "Type": "AWS::RDS::DBSubnetGroup",
#             "Properties": {
#                 "DBSubnetGroupDescription": "Subnets available for the RDS DB Instance",
#                 "SubnetIds": ${CLUSTER_SUBNET_IDS}
#             }
#         },
#         "SecurityGroup": {
#             "Type": "AWS::EC2::SecurityGroup",
#             "Properties": {
#                 "GroupDescription": "Allow access to the PostgreSQL from the Web Server",
#                 "VpcId": {
#                     "Ref": "VpcId"
#                 },
#                 "SecurityGroupIngress": [
#                     {
#                         "IpProtocol": "tcp",
#                         "FromPort": "5432",
#                         "ToPort": "5432",
#                         "CidrIp": "${CLUSTER_VPC_CIDR}"
#                     }
#                 ]
#             }
#         },
#         "PostgreSQLDB": {
#             "Type": "AWS::RDS::DBInstance",
#             "Properties": {
#                 "AllocatedStorage": {
#                     "Ref": "DBAllocatedStorage"
#                 },
#                 "AllowMajorVersionUpgrade" : "false",
#                 "AutoMinorVersionUpgrade": "true",
#                 "VPCSecurityGroups": [
#                     {
#                         "Ref": "SecurityGroup"
#                     }
#                 ],
#                 "DBName": {
#                     "Ref": "MyDBName"
#                 },
#                 "DBInstanceClass": {
#                     "Ref": "MyDBInstanceClass"
#                 },
#                 "DBInstanceIdentifier": {
#                     "Ref": "DBIdentifier"
#                 },
#                 "DBSubnetGroupName": {
#                     "Ref": "MyDBSubnetGroup"
#                 },
#                 "Engine": "postgres",
#                 "EngineVersion": {
#                     "Ref": "DBEngineVersion"
#                 },
#                 "MasterUsername": {
#                     "Ref": "DBUser"
#                 },
#                 "MasterUserPassword": {
#                     "Ref": "DBPassword"
#                 },
#                 "MultiAZ": {
#                     "Ref": "MultiAZDatabase"
#                 },
#                 "StorageType": "gp3",
#                 "StorageEncrypted" : "true",
#                 "PubliclyAccessible" : "false",
#                 "AutomaticBackupReplicationRegion": "region",
#                 "NetworkType": "IPV4",
#                 "DeletionProtection": "true",
#                 "CopyTagsToSnapshot": true,
#                 "EnableIAMDatabaseAuthentication": false,
#                 "EnablePerformanceInsights": false,
#                 "EnableCloudwatchLogsExports": [
#                     "postgresql",
#                     "upgrade"
#                 ],
#                 "DBParameterGroupName": {
#                     "Ref": "DBParameterGroupName"
#                 },
#                 "BackupRetentionPeriod": {
#                     "Ref": "BackupRetentionPeriod"
#                 },
#                 "PreferredBackupWindow": {
#                     "Ref": "PreferredBackupWindow"
#                 },
#                 "PreferredMaintenanceWindow": {
#                     "Ref": "PreferredMaintenanceWindow"
#                 },
#                 "Tags": [
#                     {
#                         "Key": "Name",
#                         "Value": {
#                             "Ref": "DBIdentifier"
#                         }
#                     },
#                     {
#                         "Key": "Environment",
#                         "Value": "${ENVIRONMENT}"
#                     },
#                     {
#                         "Key": "Product",
#                         "Value": "${PRODUCT}"
#                     },
#                     {
#                         "Key": "CreatedBy",
#                         "Value": "${CREATEDBY}"
#                     },
#                     {
#                         "Key": "Owner",
#                         "Value": "${OWNER}"
#                     }
#                 ]
#             }
#         }
#     },
#     "Outputs": {
#         "JDBCConnectionString": {
#             "Description": "JDBC connection string for database",
#             "Value": {
#                 "Fn::Join": [
#                     "",
#                     [
#                         "jdbc:postgresql://",
#                         {
#                             "Fn::GetAtt": [
#                                 "PostgreSQLDB",
#                                 "Endpoint.Address"
#                             ]
#                         },
#                         ":",
#                         {
#                             "Fn::GetAtt": [
#                                 "PostgreSQLDB",
#                                 "Endpoint.Port"
#                             ]
#                         },
#                         "/",
#                         {
#                             "Ref": "MyDBName"
#                         }
#                     ]
#                 ]
#             }
#         },
#         "DBAddress": {
#             "Description": "address of database endpoint",
#             "Value": {
#                 "Fn::GetAtt": [
#                     "PostgreSQLDB",
#                     "Endpoint.Address"
#                 ]
#             }
#         },
#         "DBPort": {
#             "Description": "database endpoint port",
#             "Value": {
#                 "Fn::GetAtt": [
#                     "PostgreSQLDB",
#                     "Endpoint.Port"
#                 ]
#             }
#         }
#     }
# }
# EOF


# aws cloudformation create-stack --retain-except-on-create \
#     --stack-name postgresql-creation-for-unisecure-lite-${CLUSTER_NAME} \
#     --parameters ParameterKey=DBPassword,ParameterValue="C1Tad3l!" \
#     --template-body file:///tmp/postgresql_rds_creation_template.json \
#     --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
#     --profile ${PROFILE}


### https://repost.aws/knowledge-center/delete-cf-stack-retain-resources
### Creating S3 Bucket with cloud formation template file
cat > /tmp/s3_buket_creation_template.json << EOF
{
    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "Cloud Formation Template To Create S3 bucket with default encryption",
    
    "Parameters" : {
        "BucketName" : {
        "Type" : "String",
        "Default" : "${S3_BUCKET_NAME}",
        "Description" : "S3 bucket name."
      }
    },
    
    "Resources": {
        "EncryptedS3Bucket": {
            "Type": "AWS::S3::Bucket",
            "DeletionPolicy": "Retain",
            "Properties": {
                "BucketName": { "Ref" : "BucketName" },
                "AccessControl": "BucketOwnerFullControl",
                "CorsConfiguration": {
                    "CorsRules": [
                        {
                            "AllowedHeaders": [
                                "*"
                            ],
                            "AllowedMethods": [
                                "GET",
                                "HEAD"
                            ],
                            "AllowedOrigins": [
                                "*"
                            ],
                            "ExposedHeaders": []
                        }
                    ]
                },
                "BucketEncryption": {
                  "ServerSideEncryptionConfiguration": [
                    {
                      "ServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                      }
                    }
                  ]
                },
                "PublicAccessBlockConfiguration": {
                  "BlockPublicAcls": true,
                  "BlockPublicPolicy": true,
                  "IgnorePublicAcls": true,
                  "RestrictPublicBuckets": true
                },
                "Tags": [
                    {
                        "Key": "Name",
                        "Value": {
                            "Ref": "BucketName"
                        }
                    },
                    {
                        "Key": "Environment",
                        "Value": "${ENVIRONMENT}"
                    },
                    {
                        "Key": "Product",
                        "Value": "${PRODUCT}"
                    },
                    {
                        "Key": "CreatedBy",
                        "Value": "${CREATEDBY}"
                    },
                    {
                        "Key": "Owner",
                        "Value": "${OWNER}"
                    }
                ]
            }
        }
    },
    "Outputs": {
        "EncryptedS3BucketARN": {
            "Description": "ARN of newly created S3 Bucket",
            "Value": {
                "Fn::GetAtt": [
                    "EncryptedS3Bucket",
                    "Arn"
                ]
            },
            "Export" : { "Name" : {"Fn::Sub": "${AWS::StackName}-S3BucketARN" }}
        }
    }
}
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name s3-bucket-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/s3_buket_creation_template.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


### Create a Security Group using cloud formation template
cat > /tmp/vpc_sg_creation_template.json << EOF
{

    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "AWS CloudFormation Template for VPC Security Group creation",
    "Parameters": {
        "VpcId": {
            "Type": "String",
            "Description": "The VPC Id",
            "Default": "${CLUSTER_VPC_ID}"
        },
        "VpcCIDR": {
            "Type": "String",
            "Description": "The VPC CIDR",
            "Default": "${CLUSTER_VPC_CIDR}"
        },
        "GroupName": {
            "Type": "String",
            "Description": "The VPC Security GroupName",
            "Default": "sdp-dev-endpoint-sg"
        }
    },

    "Resources": {
        "myEndpointSecurityGroup": {
            "Type": "AWS::EC2::SecurityGroup",
            "Properties": {
                "GroupName": {
                    "Ref": "GroupName"
                },
                "GroupDescription": "Allow HTTPS traffic from the VPC / Enpoint Services",
                "VpcId": {
                    "Ref": "VpcId"
                },
                "SecurityGroupIngress": [
                    {
                        "IpProtocol": "tcp",
                        "FromPort": 443,
                        "ToPort": 443,
                        "CidrIp": {
                            "Ref": "VpcCIDR"
                        }
                    }
                ],
                "Tags": [
                    {
                        "Key": "Name",
                        "Value": {
                            "Ref": "GroupName"
                        }
                    },
                    {
                        "Key": "Environment",
                        "Value": "${ENVIRONMENT}"
                    },
                    {
                        "Key": "Product",
                        "Value": "${PRODUCT}"
                    },
                    {
                        "Key": "CreatedBy",
                        "Value": "${CREATEDBY}"
                    },
                    {
                        "Key": "Owner",
                        "Value": "${OWNER}"
                    }
                ]
            }
        }
    },
    "Outputs": {
        "EndpointSecurityGroup": {
            "Description": "GroupId of newly created Security Group",
            "Value": {
                "Fn::GetAtt": [
                    "myEndpointSecurityGroup",
                    "GroupId"
                ]
            },
            "Export" : { "Name" : {"Fn::Sub": "${AWS::StackName}-SecurityGroupID" }}
        }
    }
}
EOF

##https://docs.aws.amazon.com/cli/latest/reference/cloudformation/wait/stack-create-complete.html

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-endpoint-security-group-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_sg_creation_template.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}

aws cloudformation wait stack-create-complete \
    --stack-name vpc-endpoint-security-group-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --profile ${PROFILE}

# aws ec2 describe-security-groups \
#   --filter Name=vpc-id,Values=${CLUSTER_VPC_ID} \
#   --filter Name=group-name,Values=sdp-dev-endpoint-sg \
#   --query SecurityGroups[].GroupId --output text \
#   --region $REGION --profile ${PROFILE}


    
### https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-vpcendpoint.html

### Create vpc endpoints using cloudformation templates
cat > /tmp/vpc_endpoint_creation_template.json << EOF
{

    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "AWS CloudFormation Template for VPC Endpoint Services",
    "Parameters": {
        "VpcId": {
            "Type": "String",
            "Description": "The VPC Id",
            "Default": "${CLUSTER_VPC_ID}"
        },
        "VpcCIDR": {
            "Type": "String",
            "Description": "The VPC CIDR",
            "Default": "${CLUSTER_VPC_CIDR}"
        },
        "SubnetIds": {
            "Type": "String",
            "Description": "The VPC SubnetIds Where the endpoint should be created",
            "Default": "${CLUSTER_VPC_CIDR}"
        },
        "EndpointName": {
            "Type": "String",
            "Description": "The VPC Security GroupName",
            "Default": "vpc-endpoint"
        },
        "EndpointServiceName": {
            "Type": "String",
            "Description": "The VPC Endpoint Service Name",
            "Default": "com.amazonaws.us-east-1.ecs-agent"
        },
        "EndpointType": {
            "Type": "String",
            "Description": "The VPC Endpoint Type",
            "Default": "Interface"
        },
        "SecurityGroupStackName": {
          "Description": "Name of an active CloudFormation stack that contains the SecurityGroup resources, such as the security group, that will be used in this stack.",
          "Type": "String",
          "MinLength" : 1,
          "MaxLength" : 255,
          "AllowedPattern" : "^[a-zA-Z][-a-zA-Z0-9]*$",
          "Default" : "vpc-endpoint-security-group-creation-for-unisecure-lite"
        }
    },

    "Resources": {
        "CWLInterfaceEndpoint": {
            "Type": "AWS::EC2::VPCEndpoint",
            "Properties": {
                "VpcEndpointType": {
                    "Ref": "EndpointType"
                },
                "ServiceName": {
                    "Ref": "EndpointServiceName"
                },
                "VpcId": {
                    "Ref": "VpcId"
                },
                "SubnetIds": ${CLUSTER_SUBNET_IDS},
                "SecurityGroupIds": [
                    {
                        "Fn::ImportValue" :  {"Fn::Sub": "${SecurityGroupStackName}-SecurityGroupID" }
                    }
                ]
            }
        }
    }
}
EOF

#aws cloudformation create-stack --retain-except-on-create \
#    --stack-name vpc-enpoint-creation-for-unisecure-lite-${CLUSTER_NAME} \
#    --template-body file:///tmp/vpc_endpoint_creation_template.json \
#    --parameters ParameterKey=EndpointName,ParameterValue=$CLUSTER_NAME-vpc-endpoint-ecr-dkr \
#    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
#    --profile ${PROFILE}

## Create the ecr-api endpoint
cat > /tmp/vpc-endpoint-creation-ecr-api-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "${CLUSTER_NAME}-vpc-endpoint-ecr-api"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.ecr.api"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-ecr-api-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-ecr-api-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}
    


## Create the ecr-dkr endpoint
cat > /tmp/vpc-endpoint-creation-ecr-dkr-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-ecr-dkr"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.ecr.dkr"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-ecr-dkr-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-ecr-dkr-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the eks endpoint
cat > /tmp/vpc-endpoint-creation-eks-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-eks"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.eks"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-eks-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-eks-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the rds endpoint
cat > /tmp/vpc-endpoint-creation-rds-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-rds"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.rds"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-rds-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-rds-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the ec2 endpoint
cat > /tmp/vpc-endpoint-creation-ec2-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-ec2"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.ec2"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-ec2-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-ec2-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the ssm endpoint
cat > /tmp/vpc-endpoint-creation-ssm-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-ssm"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.ssm"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-ssm-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-ssm-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the secretsmanager endpoint
cat > /tmp/vpc-endpoint-creation-secretsmanager-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-secretsmanager"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.secretsmanager"
        }
]
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-secretsmanager-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/vpc_endpoint_creation_template.json \
    --parameters file:///tmp/vpc-endpoint-creation-secretsmanager-params.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}


## Create the s3 gateway endpoint
cat > /tmp/vpc-endpoint-creation-s3-gateway-params.json << EOF
[
        {
            "ParameterKey": "EndpointName",
            "ParameterValue": "$CLUSTER_NAME-vpc-endpoint-s3"
        },
        {
            "ParameterKey": "EndpointServiceName",
            "ParameterValue": "com.amazonaws.${REGION}.s3"
        },
        {
            "ParameterKey": "EndpointType",
            "ParameterValue": "Gateway"
        }
]
EOF

### https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-vpcendpoint.html
### SubnetIds
### The IDs of the subnets in which to create endpoint network interfaces. You must specify this property 
### for an interface endpoint or a Gateway Load Balancer endpoint. 
### You can't specify this property for a gateway endpoint. For a Gateway Load Balancer endpoint, you can specify only one subnet.


#sed -i '/^"SubnetIds"/d' /tmp/vpc_endpoint_creation_template.json
# CLUSTER_SUBNET_ID1=`echo $CLUSTER_SUBNET_IDS_LIST | awk '{print $(NF)}'`
# CLUSTER_SUBNET_ID2=`echo $CLUSTER_SUBNET_IDS_LIST | awk '{print $(NF-1)}'`

# CLUSTER_SUBNET_IDS=${CLUSTER_SUBNET_ID1},${CLUSTER_SUBNET_ID2}

CLUSTER_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filter Name=vpc-id,Values=${CLUSTER_VPC_ID} \
    --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output json --region $REGION --profile ${PROFILE})

CLUSTER_SUBNET_ID=`echo $CLUSTER_SUBNET_IDS | awk '{print $(NF-1)}'`

### Create vpc s3 gateway endpoints using cloudformation templates
cat > /tmp/s3_gateway_vpc_endpoint_creation_template.json << EOF
{

    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "AWS CloudFormation Template for VPC Endpoint Services",

    "Resources": {
        "CWLInterfaceEndpoint": {
            "Type": "AWS::EC2::VPCEndpoint",
            "Properties": {
                "VpcEndpointType": Gateway,
                "ServiceName": "com.amazonaws.${REGION}.s3",
                "VpcId": "${CLUSTER_VPC_ID}"
            }
        }
    }
}
EOF

aws cloudformation create-stack --retain-except-on-create \
    --stack-name vpc-enpoint-s3-gateway-creation-for-unisecure-lite-${CLUSTER_NAME} \
    --template-body file:///tmp/s3_gateway_vpc_endpoint_creation_template.json \
    --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
    --profile ${PROFILE}

echo "Configure EKS Cluster for kuebctl..."
aws eks --region $REGION update-kubeconfig --name ${CLUSTER_NAME} \
    --output text --region $REGION --profile ${PROFILE}

echo "adding Public Subnets in loadbalancer.yaml in nginx-ingress"
public_subnets=$(echo "$CLUSTER_SUBNET_IDS" | grep -o '"subnet-[a-zA-Z0-9]\+"' | tr -d '"' | paste -sd "," -)
sed -i 's/{PUBLIC_SUBNETS}/'"${public_subnets}"'/g' nginx-ingress/deployments/service/loadbalancer.yaml

echo "Installing AWS Loadbalancer Controller..."
cd aws-load-balancer-controller/
chmod +x aws-load-balancer.sh
./aws-load-balancer.sh
cd ..
pwd
chmod +x secret_store_csi_driver_and_nginx_ingress_deployment.sh
./secret_store_csi_driver_and_nginx_ingress_deployment.sh

sleep 20

# Fetch all VPC endpoints in the specified VPC
ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${CLUSTER_VPC_ID}" \
    --query "VpcEndpoints[].VpcEndpointId" \
    --output text \
    --profile ${PROFILE})

echo "Found VPC Endpoint IDs: $ENDPOINT_IDS"

# Check if there are any endpoints
if [ -z "$ENDPOINT_IDS" ]; then
    echo "No VPC endpoints found in VPC ${CLUSTER_VPC_ID}."
    exit 1
fi

# Tag each VPC endpoint
for ENDPOINT_ID in $ENDPOINT_IDS; do
    # Trim any potential whitespace around IDs
    ENDPOINT_ID=$(echo $ENDPOINT_ID | xargs)
    
    if [[ ! $ENDPOINT_ID =~ vpce- ]]; then
        echo "Skipping invalid endpoint ID: $ENDPOINT_ID"
        continue
    fi

    echo "Tagging VPC endpoint: $ENDPOINT_ID"
    aws ec2 create-tags \
        --resources $ENDPOINT_ID \
        --tags Key=Environment,Value=${ENVIRONMENT} Key=Product,Value=${PRODUCT} Key=CreatedBy,Value=${CREATEDBY} Key=Owner,Value=${OWNER} \
        --profile ${PROFILE} || {
            echo "Failed to tag endpoint: $ENDPOINT_ID"
        }
done

echo "Tagging completed for VPC endpoints in VPC ${VPC_ID}."