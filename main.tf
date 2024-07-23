provider "google" {
  project = var.project_id
  region  = var.region
}

### VPC ###

# Enable VPC Access API
resource "google_project_service" "enable_vpc_access" {
  project = var.project_id
  service = "vpcaccess.googleapis.com"
}

module "vpc" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 9.0"
  project_id   = var.project_id
  network_name = "app-vpc"
  mtu          = 1460
  subnets = [
    {
      subnet_name   = "app-nodes"
      subnet_ip     = "10.0.16.0/20" # 4,096 IP addresses
      subnet_region = var.region
    },
  ]
  depends_on = [google_project_service.enable_vpc_access]
}

resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-postgres"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = module.vpc.network_name
  project       = var.project_id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = module.vpc.network_self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# create a Cloud Router for NAT from private VPC
resource "google_compute_router" "nat_router" {
  name    = "nat-router"
  network = module.vpc.network_name
  region  = var.region
  project = var.project_id
}

# create a Cloud NAT for private VPC
resource "google_compute_router_nat" "nat" {
  name                               = "nat-config"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  project                            = var.project_id
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  nat_ip_allocate_option             = "AUTO_ONLY"
}

# Allow SSH ingress from IAP
resource "google_compute_firewall" "allow_ssh_ingress_from_iap" {
  name      = "allow-ssh-ingress-from-iap"
  direction = "INGRESS"
  network   = module.vpc.network_name
  project   = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}

# Allow port 80 ingress from the internet
resource "google_compute_firewall" "allow_http_ingress" {
  name      = "allow-http-ingress"
  direction = "INGRESS"
  network   = module.vpc.network_name
  project   = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["0.0.0.0/0"]
  destination_ranges = [ "10.0.16.0/20" ]
}

### Cloud SQL ###

# Enable Cloud SQL API
resource "google_project_service" "cloud_sql_api" {
  project = var.project_id
  service = "sqladmin.googleapis.com"
}

# Enable Cloud SQL Admin API
resource "google_project_service" "cloud_sql_admin_api" {
  project = var.project_id
  service = "sql-component.googleapis.com"
}

# Enable Service Networking API
resource "google_project_service" "servicenetworking_api" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"
}

# Enable Network Management API
resource "google_project_service" "network_management_api" {
  project = var.project_id
  service = "networkmanagement.googleapis.com"
}

### Cloud SQL ###

# create a random ID for the database name
resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "postgres_db" {
  name             = "postgres-${random_id.db_name_suffix.hex}"
  database_version = "POSTGRES_15"
  region           = var.region
  project          = var.project_id
  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false                        # Disable public IP
      private_network = module.vpc.network_self_link # Use the VPC network
      ssl_mode        = "ENCRYPTED_ONLY"
    }
    activation_policy = "ALWAYS"
    availability_type = "ZONAL"
    edition           = "ENTERPRISE"
  }
  depends_on = [
    google_project_service.cloud_sql_api,
    google_project_service.servicenetworking_api,
    google_service_networking_connection.private_vpc_connection,
  ]
}

### Application Server ###

# create a service account for the application
resource "google_service_account" "app_sa" {
  account_id   = "app-sa"
  display_name = "app-sa"
  description  = "application service account"
  project      = var.project_id
}

# grant roles/iam.serviceAccountUser for Use a service account
resource "google_project_iam_binding" "app_sa_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  members = [
    "user:lance@speelmon.com",
  ]
}

# grant roles/iap.tunnelResourceAccessor for TCP forwarding
resource "google_project_iam_member" "app_sa_tunnel_resource_accessor" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:lance@speelmon.com"
}

# grant roles/compute.instanceAdmin.v1 for SSH access
resource "google_project_iam_member" "app_sa_instance_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "user:lance@speelmon.com"
}

# grant roles/compute.osLogin for OS Login
resource "google_project_iam_member" "app_sa_os_login" {
  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = "user:lance@speelmon.com"
}

# create a VM for the app server
resource "google_compute_instance" "app_vm" {
  provider = google-beta

  name         = "app-vm"
  description  = "App Server"
  machine_type = "e2-micro"
  zone         = "us-central1-a"
  project      = var.project_id
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network    = module.vpc.network_name
    subnetwork = module.vpc.subnets["us-central1/app-nodes"].self_link
  }
  can_ip_forward = false
  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
  depends_on = [
    google_compute_router.nat_router,
    google_compute_router_nat.nat,
  ]
}
