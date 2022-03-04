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

data "aws_region" "current" {}

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

data "aws_iam_policy_document" "efs_access" {
  statement {
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientRootAccess",
      "elasticfilesystem:ClientWrite"
    ]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values = [
        aws_efs_access_point.one.arn,
        aws_efs_access_point.two.arn
      ]
    }
    effect = "Allow"
    resources = [
      aws_efs_file_system.this.arn
    ]
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
  vpc_zone_identifier             = module.vpc.public_subnets
  block_device_mappings = [
    {
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 30
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
      cidr_blocks = module.vpc.vpc_cidr_block
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
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]
}

resource "aws_iam_instance_profile" "ecs_ec2_profile" {
  name = local.name
  role = aws_iam_role.ecs_ec2_role.name
}

resource "aws_iam_role" "ecs_ec2_role" {
  name               = "${local.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ]
}

resource "aws_iam_role" "ecs_general_task_execution_role" {
  name               = "${local.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ]
}

resource "aws_efs_file_system" "this" {
  #checkov:skip=CKV_AWS_184:KMS CMK not required
  encrypted       = true
  throughput_mode = "bursting"
}

resource "aws_efs_access_point" "one" {
  file_system_id = aws_efs_file_system.this.id
  posix_user {
    gid            = 48
    uid            = 48
    secondary_gids = [1402]
  }
  root_directory {
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = "0750"
    }
    path = "/path/one"
  }
}

resource "aws_efs_access_point" "two" {
  file_system_id = aws_efs_file_system.this.id
  posix_user {
    gid            = 48
    uid            = 48
    secondary_gids = [1402]
  }
  root_directory {
    creation_info {
      owner_gid   = 1500
      owner_uid   = 1402
      permissions = "0770"
    }
    path = "/path/two"
  }
}

resource "aws_ecs_task_definition" "test" {
  family                   = local.name
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_general_task_execution_role.arn
  task_role_arn            = aws_iam_role.cli.arn
  container_definitions = jsonencode([
    {
      essential         = true
      image             = "public.ecr.aws/docker/library/php:7.4-cli"
      memoryReservation = 50
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-region        = data.aws_region.current.name
          awslogs-group         = aws_cloudwatch_log_group.test.name
          awslogs-stream-prefix = "task-logs"
        }
      }
      mountPoints = [
        {
          sourceVolume  = "one"
          containerPath = "/mnt/efs/one/"
          readOnly      = false
        },
        {
          sourceVolume  = "two"
          containerPath = "/mnt/efs/two/"
          readOnly      = false
        }
      ]
      name        = local.name
      stopTimeout = 2
    }
  ])
  volume {
    name = "one"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.one.id
        iam             = "ENABLED"
      }
    }
  }
  volume {
    name = "two"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.two.id
        iam             = "ENABLED"
      }
    }
  }
}

resource "aws_iam_role" "cli" {
  name               = "${local.name}-task-cli"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role_policy.json
  inline_policy {
    name   = "allow-efs-access-points"
    policy = data.aws_iam_policy_document.efs_access.json
  }
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key:Encryption is not required
resource "aws_cloudwatch_log_group" "test" {
  #checkov:skip=CKV_AWS_158:Encryption is not required
  name              = "${local.name}-task"
  retention_in_days = 7
}
