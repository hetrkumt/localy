variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "admin_ip" {
  type = string
}

variable "subnet_ids" {
  description = "EKS 클러스터와 노드가 배치될 서브넷 ID 리스트"
  type        = list(string)
}