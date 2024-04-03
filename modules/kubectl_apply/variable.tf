variable "manifest" {
  description = "The content of manifest"
  type        = string
  default     = ""
}
variable "kubeconfig_file" {
  description = "The absolute path kubeconfig file"
  type        = string
  default     = ""
}

variable "kubectl_context" {
  description = "The kubectl context"
  type        = string
  default     = null
}

variable "ignore_delete" {
  description = "Ignore delete resource when destroying"
  type        = bool
  default     = false
}

variable "delay_before_creating" {
  description = "The second time to delay before creating"
  type        = number
  default     = 0
}

variable "delay_after_creating" {
  description = "The second time to delay after creating"
  type        = number
  default     = 0
}

variable "delay_before_detroying" {
  description = "The second time to delay before detroying"
  type        = number
  default     = 0
}

variable "delay_after_detroying" {
  description = "The second time to delay after detroying"
  type        = number
  default     = 0
}
