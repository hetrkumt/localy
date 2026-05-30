variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "admin_ip" {
  type = string
}

variable "cluster_endpoint_public_access" {
  description = "Enable access to the EKS public API endpoint."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint."
  type        = list(string)
  default     = []

  validation {
    condition = (
      !var.cluster_endpoint_public_access ||
      length(var.public_access_cidrs) > 0
    )
    error_message = "public_access_cidrs must be non-empty when cluster_endpoint_public_access is true."
  }
}

variable "cluster_security_group_additional_rules" {
  description = "Additional ingress/egress rules to attach to the cluster security group."
  type = map(object({
    type                     = string
    from_port                = number
    to_port                  = number
    protocol                 = string
    cidr_blocks              = optional(list(string))
    ipv6_cidr_blocks         = optional(list(string))
    source_security_group_id = optional(string)
    description              = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.cluster_security_group_additional_rules : (
        (try(r.cidr_blocks, null) != null && length(r.cidr_blocks) > 0) ||
        (try(r.ipv6_cidr_blocks, null) != null && length(r.ipv6_cidr_blocks) > 0) ||
        (try(r.source_security_group_id, null) != null && r.source_security_group_id != "")
      )
    ])
    error_message = "Each cluster_security_group_additional_rules entry must set at least one of cidr_blocks, ipv6_cidr_blocks, or source_security_group_id."
  }
}

variable "subnet_ids" {
  description = "EKS 클러스터와 노드가 배치될 서브넷 ID 리스트"
  type        = list(string)
}