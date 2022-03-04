locals {
  name      = "test-ecs"
  user_data = <<-EOT
  #!/bin/bash -xe
  echo ECS_CLUSTER=${module.ecs_cluster.ecs_cluster_name} >>/etc/ecs/ecs.config
  echo ECS_CONTAINER_STOP_TIMEOUT=10s >>/etc/ecs/ecs.config
  echo ECS_ENABLE_SPOT_INSTANCE_DRAINING=true >>/etc/ecs/ecs.config
  echo ECS_ENABLE_TASK_IAM_ROLE=true >>/etc/ecs/ecs.config
  echo ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=10m >>/etc/ecs/ecs.config
  echo ECS_IMAGE_PULL_BEHAVIOR=prefer-cached >>/etc/ecs/ecs.config
  echo ECS_RESERVED_MEMORY=200 >>/etc/ecs/ecs.config
  EOT
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

data "aws_iam_policy_document" "ec2_assume_role_policy" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com"
      ]
    }
  }
}

data "aws_iam_policy_document" "ecs_tasks_assume_role_policy" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~> 3.0"
  name               = local.name
  cidr               = "10.221.0.0/16"
  azs                = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  private_subnets    = ["10.221.1.0/24", "10.221.2.0/24"]
  public_subnets     = ["10.221.11.0/24", "10.221.12.0/24"]
  enable_nat_gateway = false
}

module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 3.0"

  name               = local.name
  container_insights = false
  capacity_providers = [
    aws_ecs_capacity_provider.scaling.name
  ]
  default_capacity_provider_strategy = [
    {
      capacity_provider = aws_ecs_capacity_provider.scaling.name
      weight            = 100
    }
  ]
}

resource "aws_ecs_capacity_provider" "scaling" {
  name = local.name
  auto_scaling_group_provider {
    auto_scaling_group_arn         = module.asg_scaling.autoscaling_group_arn
    managed_termination_protection = "ENABLED"
    managed_scaling {
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
      instance_warmup_period    = 60
    }
  }
}

module "asg_scaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 5.0"

  capacity_rebalance              = true
  create_launch_template          = true
  default_cooldown                = 60
  desired_capacity                = null
  ebs_optimized                   = true
  enable_monitoring               = false
  force_delete                    = false
  health_check_grace_period       = 60
  health_check_type               = "EC2"
  iam_instance_profile_arn        = aws_iam_instance_profile.ecs_ec2_profile.arn
  image_id                        = jsondecode(data.aws_ssm_parameter.ami.value).image_id
  instance_type                   = "t3.small"
  launch_template_description     = "Launch template for the ECS EC2 cluster"
  launch_template_name            = local.name
  launch_template_use_name_prefix = false
  launch_template_version         = "$Latest"
  max_size                        = 2
  min_size                        = 1
  name                            = local.name
  protect_from_scale_in           = true
  update_default_version          = true
  use_name_prefix                 = false
  user_data_base64                = base64encode(local.user_data)
  vpc_zone_identifier             = module.vpc.private_subnets
  block_device_mappings = [
    {
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 20
        volume_type           = "gp3"
      }
    }
  ]
  credit_specification = {
    cpu_credits = "unlimited"
  }
  enabled_metrics = [
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]
  security_groups = [
    module.ecs_ec2_sg.security_group_id
  ]
  tags = {
    AmazonECSManaged = ""
  }
}

module "ecs_ec2_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name   = local.name
  vpc_id = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      from_port   = 32768
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_id.private_subnets_cidr_blocks
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 32768
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_id.private_subnets_cidr_blocks
    },
  ]
}

resource "aws_iam_instance_profile" "ecs_ec2_profile" {
  name = local.name
  role = aws_iam_role.ecs_ec2_role.name
}

resource "aws_iam_role" "ecs_ec2_role" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ]
}

resource "aws_iam_role" "ecs_general_task_execution_role" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ]
}
