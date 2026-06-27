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
}

provider "aws" {
  region = "us-east-1"
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
    Name                               = "namegen-public-1"
    "kubernetes.io/role/elb"           = "1"
    "kubernetes.io/cluster/namegen-cluster" = "shared"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.namegen_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                               = "namegen-public-2"
    "kubernetes.io/role/elb"           = "1"
    "kubernetes.io/cluster/namegen-cluster" = "shared"
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
# 3. הרשאות ואבטחה לקלאסטר ולשרתים (IAM Roles)
# ==========================================

# א. Role עבור ה"מוח" המנהל של קלאסטר ה-EKS
resource "aws_iam_role" "eks_role" {
  name_prefix = "namegen-eks-role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = join("", ["eks", ".", "amazonaws", ".com"])
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
          Service = join("", ["ec2", ".", "amazonaws", ".com"])
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

# ==========================================
# 4. הקמת קלאסטר ה-EKS (במצב Auto Mode)
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
    aws_iam_role_policy_attachment.eks_node_policy
  ]
}

# ==========================================
# 5. 🌟 תוספת חובה: כרטיס כניסה והרשאות Admin פנימיות לקוברנטיס
# ==========================================
resource "aws_eks_access_entry" "pipeline_access" {
  cluster_name  = aws_eks_cluster.namegen_cluster.name
  principal_arn = aws_iam_role.eks_role.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin_policy" {
  cluster_name  = aws_eks_cluster.namegen_cluster.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.eks_role.arn

  access_scope {
    type = "cluster"
  }
}
