resource "scaleway_instance_placement_group" "availability_group" {
  policy_type = "max_availability"
  policy_mode = "enforced"
}

data "scaleway_k8s_version" "latest" {
  name = "latest"
}

resource "scaleway_vpc" "kapsule" {
    name = "vpc_kapsule"
    tags = ["kapsule"]
}

resource "scaleway_vpc_private_network" "kapsule" {
  name   = "pn_kapsule"
  vpc_id = scaleway_vpc.kapsule.id
  tags   = ["kapsule"]
}

resource "scaleway_k8s_cluster" "k8s_cluster" {
  name                        = "demo-cluster"
  version                     = data.scaleway_k8s_version.latest.name
  cni                         = "cilium"
  private_network_id          = scaleway_vpc_private_network.kapsule.id
  delete_additional_resources = true
  depends_on                  = [scaleway_vpc_private_network.kapsule]

  autoscaler_config {
    disable_scale_down               = false
    scale_down_unneeded_time         = "2m"
    scale_down_delay_after_add       = "30m"
    scale_down_utilization_threshold = 0.5
    estimator                        = "binpacking"
    expander                         = "random"
    ignore_daemonsets_utilization    = true
  }
}

resource "scaleway_k8s_pool" "k8s_pool" {
  name               = "demo-pool"
  cluster_id         = scaleway_k8s_cluster.k8s_cluster.id
  node_type          = "DEV1-M"
  size               = 1
  min_size           = 1
  max_size           = 10
  autoscaling        = true
  autohealing        = true
  container_runtime  = "containerd"
  placement_group_id = scaleway_instance_placement_group.availability_group.id
}

variable "hide" { # Workaround to hide local-exec output
  default   = "yes"
  sensitive = true
}

resource "null_resource" "kubeconfig" {
  depends_on = [scaleway_k8s_pool.k8s_pool]
  triggers = {
    host                   = scaleway_k8s_cluster.k8s_cluster.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.k8s_cluster.kubeconfig[0].token
    cluster_ca_certificate = scaleway_k8s_cluster.k8s_cluster.kubeconfig[0].cluster_ca_certificate
  }

  provisioner "local-exec" {
    environment = {
      HIDE_OUTPUT = var.hide # Workaround to hide local-exec output
    }
    command = <<-EOT
    cat<<EOF>kubeconfig.yaml
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: ${self.triggers.cluster_ca_certificate}
        server: ${self.triggers.host}
      name: ${scaleway_k8s_cluster.k8s_cluster.name}
    contexts:
    - context:
        cluster: ${scaleway_k8s_cluster.k8s_cluster.name}
        user: admin
      name: admin@${scaleway_k8s_cluster.k8s_cluster.name}
    current-context: admin@${scaleway_k8s_cluster.k8s_cluster.name}
    kind: Config
    preferences: {}
    users:
    - name: admin
      user:
        token: ${self.triggers.token}
    EOF
    EOT
  }
}

provider "kubernetes" {
  host                   = null_resource.kubeconfig.triggers.host
  token                  = null_resource.kubeconfig.triggers.token
  cluster_ca_certificate = base64decode(null_resource.kubeconfig.triggers.cluster_ca_certificate)
}

resource "time_sleep" "wait_for_cluster" { # wait 1 minute for cluster to stabilize (CNI, etc...)
  depends_on      = [null_resource.kubeconfig]
  create_duration = "60s"
}

resource "kubernetes_deployment" "deployment" {
  depends_on = [time_sleep.wait_for_cluster]
  metadata {
    labels = {
      app = "test"
    }
    name      = "test"
    namespace = "default"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "test"
      }
    }

    template {
      metadata {
        labels = {
          app = "test"
        }
      }
      spec {
        container {
          image = "k8s.gcr.io/hpa-example"
          name  = "test"
          resources {
            limits = {
              cpu    = "500m"
              memory = "1048Mi"
            }
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "service" {
  depends_on = [time_sleep.wait_for_cluster]
  metadata {
    annotations = {
      "service.beta.kubernetes.io/scw-loadbalancer-forward-port-algorithm" = "roundrobin"
      "service.beta.kubernetes.io/scw-loadbalancer-sticky-sessions"        = "none"
      "service.beta.kubernetes.io/scw-loadbalancer-type"                   = "LB-GP-M"
    }
    labels = {
      app = "test"
    }
    name      = "test"
    namespace = "default"
  }
  spec {
    port {
      name        = "http"
      protocol    = "TCP"
      port        = 80
      target_port = 80
    }
    selector = {
      app = "test"
    }
    type = "LoadBalancer"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "hpa" {
  depends_on = [kubernetes_deployment.deployment]
  metadata {
    name      = "test"
    namespace = "default"
  }

  spec {
    max_replicas = 20
    min_replicas = 1

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "test"
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          average_utilization = 50
          type                = "Utilization"
        }
      }
    }
  }

}
