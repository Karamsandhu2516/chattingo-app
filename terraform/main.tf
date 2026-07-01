# ==========================================
# 1. VPC & INTERNET GATEWAY
# ==========================================
resource "aws_vpc" "chattingo_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "chattingo_igw" {
  vpc_id = aws_vpc.chattingo_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ==========================================
# 2. HIGH-AVAILABILITY SUBNETS (MULTI-AZ)
# ==========================================
data "aws_availability_zones" "available" {
  state = "available"
}

# Dynamic Public Subnets
resource "aws_subnet" "chattingo_public_subnet" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.chattingo_vpc.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-public-subnet-${count.index + 1}"
    "kubernetes.io/role/elb" = "1" # Required by EKS for internet-facing Load Balancers
  }
}

# Dynamic Private Subnets
resource "aws_subnet" "chattingo_private_subnet" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.chattingo_vpc.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                              = "${var.project_name}-private-subnet-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1" # Required by EKS for internal Load Balancers
  }
}

# ==========================================
# 3. ROUTING
# ==========================================
resource "aws_route_table" "chattingo_public_route_table" {
  vpc_id = aws_vpc.chattingo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.chattingo_igw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "chattingo_public_route_table_association" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.chattingo_public_subnet[count.index].id
  route_table_id = aws_route_table.chattingo_public_route_table.id
}

# ==========================================
# 4. SECURITY (APP PLATFORM SECURITY GROUP)
# ==========================================
resource "aws_security_group" "chattingo_sg" {
  name        = "${var.project_name}-sg"
  description = "Security group for Chattingo compute layer"
  vpc_id      = aws_vpc.chattingo_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# ==========================================
# 5. AMAZON ECR REPOSITORIES
# ==========================================
resource "aws_ecr_repository" "frontend" {
  name                 = "frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend" {
  name                 = "backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ==========================================
# 6. DATABASE NETWORKING & SECURITY
# ==========================================
resource "aws_db_subnet_group" "chattingo_db_subnet_group" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.chattingo_private_subnet[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "chattingo_db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "Allow inbound MySQL traffic from compute layer"
  vpc_id      = aws_vpc.chattingo_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.chattingo_sg.id]
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.chattingo_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 7. AWS RDS MYSQL INSTANCE
# ==========================================
resource "aws_db_instance" "chattingo_db" {
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage   = 20
  db_name             = "chattingo_db"
  username            = "chattingo"
  password            = var.db_password
  skip_final_snapshot = true

  db_subnet_group_name   = aws_db_subnet_group.chattingo_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.chattingo_db_sg.id]

  tags = {
    Name = "${var.project_name}-db"
  }
}

# ==========================================
# 8. EKS CLUSTER IAM SECURITY ROLES
# ==========================================
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# ==========================================
# 9. AWS EKS CONTROL PLANE
# ==========================================
resource "aws_eks_cluster" "chattingo_cluster" {
  name     = "${var.project_name}-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = concat(aws_subnet.chattingo_public_subnet[*].id, aws_subnet.chattingo_private_subnet[*].id)
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ==========================================
# 10. EKS WORKER NODES IAM SECURITY ROLES
# ==========================================
resource "aws_iam_role" "eks_nodes_role" {
  name = "${var.project_name}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes_role.name
}

# ==========================================
# 11. EKS WORKER NODE GROUP (COMPUTE POOL)
# ==========================================
resource "aws_eks_node_group" "chattingo_nodes" {
  cluster_name    = aws_eks_cluster.chattingo_cluster.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = aws_iam_role.eks_nodes_role.arn
  subnet_ids      = aws_subnet.chattingo_public_subnet[*].id

  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_container_registry_read_only,
  ]
}