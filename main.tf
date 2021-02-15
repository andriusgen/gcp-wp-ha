// Configure the Google Cloud provider
provider "google" {
 credentials = file("service-account.json")
 project     = var.project_id
}

//Configuring Kubernetes Provider
# Retrieve an access token as the Terraform runner
data "google_client_config" "provider" {}

data "google_container_cluster" "wp-cluster" {
  name     = "my-cluster"
  location = var.region1
}

provider "kubernetes" {
  host  = "https://${data.google_container_cluster.wp-cluster.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    data.google_container_cluster.wp-cluster.master_auth[0].cluster_ca_certificate,
  )
}


//Configuring VPC with a private IP address range
resource "google_compute_network" "vpc" {
    name        = "prod-wp-env"
    description = "VPC Network for WordPress"
    project     = var.project_id
    routing_mode            = "GLOBAL"
    auto_create_subnetworks = true
}


//Allocating a block of private IP addresses
resource "google_compute_global_address" "private_ip_block" {
  name         = "private-ip-block"
  purpose      = "VPC_PEERING"
  address_type = "INTERNAL"
  ip_version   = "IPV4"
  prefix_length = 20
  network       = google_compute_network.vpc.self_link
}

//Enabling private service account 
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
}


//Firewall rule to allow ingress SSH traffic
resource "google_compute_firewall" "allow_ssh" {
  name        = "allow-ssh"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags = ["ssh-enabled"]
}

//Configuring SQL Database instance
resource "google_sql_database_instance" "sqldb_Instance_wp" {
  name             = "wp-sql-ha"
  database_version = "MYSQL_5_6"
  region           = var.region2
  root_password    = var.root_pass
  depends_on       = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_size         = 10 
    
    backup_configuration {
      enabled = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.self_link
    }
  }
}


//Creating SQL Database
resource "google_sql_database" "sql_db" {
  name     = var.database
  instance = google_sql_database_instance.sqldb_Instance_wp.name

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]  
}

//Creating SQL Database User
resource "google_sql_user" "dbUser" {
  name     = var.db_user
  instance = google_sql_database_instance.sqldb_Instance_wp.name
  password = var.db_user_pass

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]
}

//Creating Container Cluster
resource "google_container_cluster" "wp-cluster" {
  name     = "my-cluster"
  description = "My GKE Cluster"
  project = var.project_id
  location = var.region1
  remove_default_node_pool = true
  initial_node_count       = 1

}

//Creating Node Pool For Container Cluster
resource "google_container_node_pool" "nodepool_wp_1" {
  name       = "my-node-pool"
  project    = var.project_id
  location   = var.region1
  cluster    = google_container_cluster.wp-cluster.name
  node_count = 1

  node_config {
    preemptible  = true
    machine_type = "e2-micro"
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }
}

//Set Current Project in gcloud SDK
resource "null_resource" "set_gcloud_project" {
  provisioner "local-exec" {
    command = "gcloud config set project ${var.project_id}"
  }  
}

//Configure Kubectl with Our GCP K8s Cluster
resource "null_resource" "configure_kubectl" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${google_container_cluster.wp-cluster.name} --region ${google_container_cluster.wp-cluster.location} --project ${google_container_cluster.wp-cluster.project}"
  }  

  depends_on = [
    null_resource.set_gcloud_project,
    google_container_cluster.wp-cluster
  ]
}

//WordPress Deployment
resource "kubernetes_deployment" "wp-dep" {
  metadata {
    name   = "wp-dep"
    labels = {
      env     = "Production"
    }
  }

  spec {
    replicas = 3
    selector {
      match_labels = {
        pod     = "wp"
        env     = "Production"
      }
    }

    template {
      metadata {
        labels = {
          pod     = "wp"
          env     = "Production"
        }
      }

      spec {
        container {
          image = "wordpress"
          name  = "wp-container"

          env {
            name  = "WORDPRESS_DB_HOST"
            value = "google_sql_database_instance.sqldb_Instance_wp.ip_address.0.ip_address"
          }
          env {
            name  = "WORDPRESS_DB_USER"
            value = var.db_user
          }
          env {
            name  = "WORDPRESS_DB_PASSWORD"
            value = var.db_user_pass
          }
          env{
            name  = "WORDPRESS_DB_NAME"
            value = var.database
          }
          env{
            name  = "WORDPRESS_TABLE_PREFIX"
            value = "wp_"
          }

          port {
            container_port = 80
          }
        }
      }
    }
  }

  depends_on = [
    null_resource.set_gcloud_project,
    google_container_cluster.wp-cluster,
    google_container_node_pool.nodepool_wp_1,
    null_resource.configure_kubectl
  ]
}

//Creating LoadBalancer Service
resource "kubernetes_service" "wpService" {
  metadata {
    name   = "wp-svc"
    labels = {
      env     = "Production" 
    }
  }  

  spec {
    type     = "LoadBalancer"
    selector = {
      pod = "kubernetes_deployment.wp-dep.spec.0.selector.0.match_labels.pod"
    }

    port {
      name = "wp-port"
      port = 80
    }
  }

  depends_on = [
    kubernetes_deployment.wp-dep,
  ]
}

//Outputs
output "wp_service_url" {
  value = "kubernetes_service.wpService.status[0].load_balancer[0].ingress[0].ip"

  depends_on = [
    kubernetes_service.wpService
  ]
}

output "db_host" {
  value = google_sql_database_instance.sqldb_Instance_wp.ip_address.0.ip_address

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]
}

output "database_name" {
  value = var.database

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]
}

output "db_user_name" {
  value = var.db_user

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]
}

output "db_user_passwd" {
  value = var.db_user_pass

  depends_on = [
    google_sql_database_instance.sqldb_Instance_wp
  ]
}

//Open WordPress Site Automatically
resource "null_resource" "open_wp" {
  provisioner "local-exec" {
    command = "start chrome ${kubernetes_service.wpService.status[0].load_balancer[0].ingress[0].ip}" 
  }

  depends_on = [
    kubernetes_service.wpService
  ]
}
