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

# שער לאינטרנט
resource "aws_internet_gateway" "namegen_igw" {
  vpc_id = aws_vpc.namegen_vpc.id

  tags = {
    Name = "namegen-igw"
  }
}

# סאבנט ציבורי 1
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

# סאבנט ציבורי 2
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

# טבלת ניתוב שמחברת את הסאבנטים לאינטרנט
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

# חיבור סאבנט 1 לטבלת הניתוב
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

# חיבור סאבנט 2 לטבלת הניתוב
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# ==========================================
# 3. הרשאות ואבטחה לקלאסטר (IAM Roles)
# ==========================================
resource "aws_iam_role" "eks_role" {
  name = "namegen-eks-role-v2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "://amazonaws.com"
        }
      }
    ]
  })
}

# חיבור פוליסי בסיסי לניהול קלאסטר EKS
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

# ==========================================
# 4. הקמת קלאסטר ה-EKS (במצב Auto Mode)
# ==========================================
resource "aws_eks_cluster" "namegen_cluster" {
  name     = "namegen-cluster"
  role_arn = aws_iam_role.eks_role.arn
  version  = "1.31" 

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids = [
      aws_subnet.public_subnet_1.id,
      aws_subnet.public_subnet_2.id
    ]
  }

  compute_config {
    enabled    = true
    node_pools = ["general-purpose"]
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
    aws_iam_role_policy_attachment.eks_policy,
    aws_iam_role_policy_attachment.eks_compute_policy,
    aws_iam_role_policy_attachment.eks_block_storage_policy,
    aws_iam_role_policy_attachment.eks_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_networking_policy
  ]
}
