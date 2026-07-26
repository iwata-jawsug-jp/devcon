# Networking (network.tf, endpoints.tf): VPC, subnets, IGW, route tables,
# security groups + rules, VPC endpoints. EC2 doesn't support resource-level
# ARN restriction for most of these actions (its managed policies like
# AmazonVPCFullAccess use Resource "*" too), so this is scoped by action
# rather than resource — still far narrower than PowerUserAccess, which grants
# every EC2 action plus ~350 other services this project doesn't use.
data "aws_iam_policy_document" "ci_deploy_network" {
  statement {
    sid    = "Ec2Networking"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeSubnets",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:DescribeInternetGateways",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DescribeRouteTables",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      # Required by ELBv2's CreateLoadBalancer call (aws_lb.api, api.tf) --
      # missing this caused AccessDenied on the first-ever ALB creation in a
      # fresh environment (#437, devcon-test#15).
      "ec2:GetSecurityGroupsForVpc",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      # In-place update of a rule declared with the modern
      # aws_vpc_security_group_{ingress,egress}_rule resources (network.tf,
      # endpoints.tf use these exclusively) -- changing a description, port
      # range, CIDR or referenced SG makes the provider call
      # ModifySecurityGroupRules rather than revoke+authorize. Never hit so far
      # because the sandbox rebuilds from scratch every time and only exercises
      # the create path; the first in-place edit on main would have failed with
      # AccessDenied (#651, found by static audit, not by a real apply).
      #
      # The older UpdateSecurityGroupRuleDescriptions{Ingress,Egress} pair that
      # used to sit here was dropped in the same change: those are what the
      # legacy aws_security_group_rule / inline ingress-egress blocks call, and
      # this repo declares neither (#651). They were write permissions, so
      # removing them is a real reduction, not cosmetic.
      "ec2:ModifySecurityGroupRules",
      "ec2:DescribeVpcEndpoints",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyVpcEndpoint",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
      # Read-only prefix-list lookup the AWS provider does while "flattening" a
      # VPC endpoint (both gateway and interface) -- distinct from the
      # DescribeManagedPrefixLists/GetManagedPrefixListEntries pair above.
      # Missing this caused every aws_vpc_endpoint apply to fail (#258).
      "ec2:DescribePrefixLists",
      # Also part of interface-endpoint "flattening": reading the ENIs the
      # endpoint attached, to populate its subnet/network-interface
      # attributes on every plan/apply refresh, not just first create (#258).
      "ec2:DescribeNetworkInterfaces",
      # A VPC-attached Lambda (worker.tf, #640) owns ENIs in its subnets/security group
      # that outlive the function itself (Hyperplane ENI lifecycle). Destroying the
      # subnet/security group makes the provider try to force-delete those leftover
      # ENIs first -- without this, `terraform destroy` fails with AccessDenied on
      # ec2:DeleteNetworkInterface (CloudTrail-evidenced in sandbox, #640; ECS's own
      # awsvpc-mode ENIs never hit this because ECS itself reclaims them on task stop,
      # before Terraform ever gets to the subnet).
      "ec2:DeleteNetworkInterface",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeTags",
    ]
    resources = ["*"]

    # EC2 networking is entirely regional; nothing here legitimately targets a
    # region other than where this project's infra lives (#45).
    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}
