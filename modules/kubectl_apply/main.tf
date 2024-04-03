resource "random_string" "suffix" {
  length  = 12
  special = false
  numeric = true
}

resource "local_file" "manifest" {
  filename        = abspath("${path.root}/.terraform/tmp/manifest-${random_string.suffix.result}.yml")
  file_permission = "0600"
  content         = var.manifest
}

locals {
  kubectl_context_param = var.kubectl_context == null || var.kubectl_context == "" ? "" : "--context ${var.kubectl_context}"
}
resource "null_resource" "this" {
  triggers = {
    manifest               = var.manifest
    apply_command          = "export KUBECONFIG=${var.kubeconfig_file}; kubectl ${local.kubectl_context_param} apply -f ${local_file.manifest.filename}"
    delete_command         = "if [[ \"${var.ignore_delete}\" == false ]]; then export KUBECONFIG=${var.kubeconfig_file}; kubectl ${local.kubectl_context_param} delete -f ${local_file.manifest.filename};fi"
    delay_before_creating  = var.delay_before_creating
    delay_after_creating   = var.delay_after_creating
    delay_before_detroying = var.delay_before_detroying
    delay_after_detroying  = var.delay_after_detroying
  }

  # invokes a local executable after a resource is created
  provisioner "local-exec" {
    # We should specify context in case we have many contexts in kubeconfig
    when       = create
    command    = "sleep ${self.triggers.delay_before_creating}; ${self.triggers.apply_command} && sleep ${self.triggers.delay_after_creating}"
    on_failure = continue
  }
  provisioner "local-exec" {
    # We should specify context in case we have many contexts in kubeconfig
    when       = destroy
    command    = "sleep ${self.triggers.delay_before_detroying}; ${self.triggers.delete_command} && sleep ${self.triggers.delay_after_detroying}"
    on_failure = continue
  }
  depends_on = [
    local_file.manifest,
  ]
}