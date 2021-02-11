// Configure the Google Cloud provider
provider "google" {
 credentials = file("service-account.json")
 project     = var.project_id
}

//Configuring Kubernetes Provider
# Retrieve an access token as the Terraform runner
data "google_client_config" "provider" {}

data "google_container_cluster" "my_cluster" {
  name     = "my-cluster"
  location = "europe-west1"
}

provider "kubernetes" {
 # load_config_file = false

  host  = "https://${data.google_container_cluster.my_cluster.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    data.google_container_cluster.my_cluster.master_auth[0].cluster_ca_certificate,
  )
}

//Creating First VPC Network
resource "google_compute_network" "vpc_network_wp_1" {
  name        = "prod-wp-env"
  description = "VPC Network for WordPress"
  project     = var.project_id
  auto_create_subnetworks = false
}

//Creating Subnetwork for First VPC
resource "google_compute_subnetwork" "subnetwork_wp_1" {
  name          = "wp-subnet"
  ip_cidr_range = "10.2.0.0/16"
  project       = var.project_id
  region        = var.region1
  network       = google_compute_network.vpc_network_wp_1.id

  depends_on = [
    google_compute_network.vpc_network_wp_1
  ]
}

//Creating Firewall for First VPC Network
resource "google_compute_firewall" "firewall_wp_1" {
  name    = "wp-firewall"
  network = google_compute_network.vpc_network_wp_1.name

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }

  source_tags = ["wp", "wordpress"]

  depends_on = [
    google_compute_network.vpc_network_wp_1
  ]
}

//Creating Second VPC Network
resource "google_compute_network" "vpc_network_wp_2" {
  name        = "prod-db-env"
  description = "VPC Network For dataBase"
  project     = var.project_id
  auto_create_subnetworks = false
}

//Creating Network For Second VPC
resource "google_compute_subnetwork" "subnetwork_wp_2" {
  name          = "db-subnet"
  ip_cidr_range = "10.4.0.0/16"
  project       = var.project_id
  region        = var.region2
  network       = google_compute_network.vpc_network_wp_2.id

  depends_on = [
    google_compute_network.vpc_network_wp_2
  ]
}

//Creating Firewall for Second VPC Network
resource "google_compute_firewall" "firewall_wp_2" {
  name    = "db-firewall"
  network = google_compute_network.vpc_network_wp_2.name

  allow {
    protocol = "tcp"
    ports    = ["80", "8080", "3306"]
  }

  source_tags = ["db", "database"]

  depends_on = [
    google_compute_network.vpc_network_wp_2
  ]
}

//VPC Network Peering1 
resource "google_compute_network_peering" "peering_wp_1" {
  name         = "wp-to-db"
  network      = google_compute_network.vpc_network_wp_1.id
  peer_network = google_compute_network.vpc_network_wp_2.id

  depends_on = [
    google_compute_network.vpc_network_wp_1,
    google_compute_network.vpc_network_wp_2
  ]
}

//VPC Network Peering2
resource "google_compute_network_peering" "peering_wp_2" {
  name         = "db-to-wp"
  network      = google_compute_network.vpc_network_wp_2.id
  peer_network = google_compute_network.vpc_network_wp_1.id

  depends_on = [
    google_compute_network.vpc_network_wp_1,
    google_compute_network.vpc_network_wp_2
  ]
}

//Configuring SQL Database instance
resource "google_sql_database_instance" "sqldb_Instance_wp" {
  name             = "sql2"
  database_version = "MYSQL_5_6"
  region           = var.region2
  root_password    = var.root_pass

  settings {
    tier = "db-f1-micro"

    ip_configuration {
      ipv4_enabled = true

      authorized_networks {
        name  = "sqlnet"
        value = "0.0.0.0/0"
      }
    }
  }

  depends_on = [
    google_compute_subnetwork.subnetwork_wp_2
  ]
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
resource "google_container_cluster" "gke_cluster_wp_1" {
  name     = "my-cluster"
  description = "My GKE Cluster"
  project = var.project_id
  location = var.region1
  network = google_compute_network.vpc_network_wp_1.name
  subnetwork = google_compute_subnetwork.subnetwork_wp_1.name
  remove_default_node_pool = true
  initial_node_count       = 1

  depends_on = [
    google_compute_subnetwork.subnetwork_wp_1
  ]
}

//Creating Node Pool For Container Cluster
resource "google_container_node_pool" "nodepool_wp_1" {
  name       = "my-node-pool"
  project    = var.project_id
  location   = var.region1
  cluster    = google_container_cluster.gke_cluster_wp_1.name
  node_count = 1

  node_config {
    preemptible  = true
    machine_type = "e2-micro"
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  depends_on = [
    google_container_cluster.gke_cluster_wp_1
  ]
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
    command = "gcloud container clusters get-credentials ${google_container_cluster.gke_cluster_wp_1.name} --region ${google_container_cluster.gke_cluster_wp_1.location} --project ${google_container_cluster.gke_cluster_wp_1.project}"
  }  

  depends_on = [
    null_resource.set_gcloud_project,
    google_container_cluster.gke_cluster_wp_1
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
    replicas = 1
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
    google_container_cluster.gke_cluster_wp_1,
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