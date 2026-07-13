# ==========================================
# 1. הגדרות ספק הענן וגרסאות (Providers)
# ==========================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70" 
    }
  }
  backend "s3" {
    bucket = "namegen-terraform-state-1712"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# משתנה פנימי לקבלת ה-Account ID של החשבון הנוכחי
data "aws_caller_identity" "current" {}

variable "enable_eks" {
  type    = bool
  default = true
}

# ==========================================
# 2. הגדרות רשת (VPC & Networking)
# ==========================================
resource "aws_vpc" "namegen_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "namegen-custom-vpc"
  }
}

resource "aws_internet_gateway" "namegen_igw" {
  vpc_id = aws_vpc.namegen_vpc.id

  tags = {
    Name = "namegen-igw"
  }
}

resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.namegen_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name                                    = "namegen-public-1"
    "kubernetes.io/role/elb"                = "1"
    "kubernetes.io/cluster/namegen-cluster" = "owned" # עודכן מ-shared ל-owned לטובת Auto Mode
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.namegen_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                                    = "namegen-public-2"
    "kubernetes.io/role/elb"                = "1"
    "kubernetes.io/cluster/namegen-cluster" = "owned" # עודכן מ-shared ל-owned לטובת Auto Mode
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.namegen_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.namegen_igw.id
  }

  tags = {
    Name = "namegen-public-rt"
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# ==========================================
# 3. הגדרת מאגר האימג'ים (Amazon ECR)
# ==========================================
resource "aws_ecr_repository" "namegen_repo" {
  name                 = "namegen"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "namegen-ecr-repo"
  }
}

# ==========================================
# 4. מנגנון האבטחה וההרשאות ל-GitHub Actions (OIDC)
# ==========================================

# א. הקמת ה-OIDC Identity Provider מול שרתי GitHub
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://githubusercontent.com"
  client_id_list  = ["://amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# ב. יצירת ה-IAM Role שה-Pipeline של GitHub Actions יעטה על עצמו באופן זמני
resource "aws_iam_role" "github_actions_role" {
  name = "namegen-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "://githubusercontent.com:aud" = "://amazonaws.com"
          }
          StringLike = {
            # הרשאה מוגבלת אך ורק לריפו הספציפי שלך ולברוס הראשי/עבודה
            "://githubusercontent.com:sub" = "repo:agandman1712-rgb/namegen_V21.6:*"
          }
        }
      }
    ]
  })
}

# ג. הצמדת פוליסי המאפשר ל-Pipeline לנהל את ECR ולדבר עם ה-EKS
resource "aws_iam_policy" "github_actions_policy" {
  name = "namegen-github-actions-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = aws_eks_cluster.namegen_cluster.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.github_actions_policy.arn
}

# ==========================================
# 5. הרשאות ואבטחה לקלאסטר ולשרתים (IAM Roles)
# ==========================================

# א. Role עבור ה"מוח" المנהל של קלאסטר ה-EKS
resource "aws_iam_role" "eks_role" {
  name_prefix = "namegen-eks-role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_role.name
}

resource "aws_iam_role_policy_attachment" "eks_compute_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.eks_role.name
}

resource "aws_iam_role_policy_attachment" "eks_block_storage_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.eks_role.name
}

resource "aws_iam_role_policy_attachment" "eks_load_balancing_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.eks_role.name
}

resource "aws_iam_role_policy_attachment" "eks_networking_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.eks_role.name
}

# ב. Role עבור השרתים האוטומטיים (מכונות ה-EC2) ש-Auto Mode מקים לבד
resource "aws_iam_role" "eks_node_role" {
  name_prefix = "namegen-node-role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_node_compute" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_node_lb" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_node_net" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.eks_node_role.name
}

# ==========================================
# 6. הקמת קלאסטר ה-EKS (במצב Auto Mode)
# ==========================================
resource "aws_eks_cluster" "namegen_cluster" {
  name                          = "namegen-cluster"
  role_arn                      = aws_iam_role.eks_role.arn
  version                       = "1.31" 
  bootstrap_self_managed_addons = false 

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids = [
      aws_subnet.public_subnet_1.id,
      aws_subnet.public_subnet_2.id
    ]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true 
  }

  compute_config {
    enabled       = true
    node_role_arn = aws_iam_role.eks_node_role.arn 
    node_pools    = ["general-purpose"]
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  depends_on = [
    aws_iam_role.eks_role,
    aws_iam_role.eks_node_role,
    aws_iam_role_policy_attachment.eks_policy,
    aws_iam_role_policy_attachment.eks_compute_policy,
    aws_iam_role_policy_attachment.eks_block_storage_policy,
    aws_iam_role_policy_attachment.eks_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_networking_policy,
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_node_compute,  
    aws_iam_role_policy_attachment.eks_node_lb,      
    aws_iam_role_policy_attachment.eks_node_net  
  ]
}

# ==========================================
# 7. מתן כרטיס כניסת Admin פנימי בקוברנטיס ל-GitHub Actions Role
# ==========================================
resource "aws_eks_access_entry" "github_pipeline_access" {
  cluster_name  = aws_eks_cluster.namegen_cluster.name
  principal_arn = aws_iam_role.github_actions_role.arn # מאפשר ל-Pipeline להיכנס לקלאסטר
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_admin_policy" {
  cluster_name  = aws_eks_cluster.namegen_cluster.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.github_actions_role.arn

  access_scope {
    type = "cluster"
  }
}

# פלט קריטי עבור המשתמש - מחזיר את ה-ARN שצריך להכניס לגיטהאב
output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_role.arn
  description = "העתק את הערך הזה ל-GitHub Actions Secrets תחת השם AWS_ROLE_TO_ASSUME"
}

import {
  to = aws_route_table_association.public_2
  id = "10.0.2.0/24/rtb-08367dfe600d9624a"
}
