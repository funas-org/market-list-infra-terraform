terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.8.0"
    }
  }
}

locals {
  prod_env = ".env"
}

module "prod_env" {
  source = "./env-variables"
  file_name = local.prod_env
}

provider "google" {
  project = "lista-de-compras-438114"
  region  = "us-central1"
  zone    = "us-central1-c"
}

resource "google_compute_network" "vpc_network" {
  name = "terraform-network"
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Ou restrinja a IPs específicos, se necessário.
  target_tags   = ["allow-ssh-tag"]
}

resource "google_compute_instance" "vm_instance" {
  depends_on   = [google_compute_firewall.allow_ssh]
  name         = "terraform-instance"
  machine_type = "e2-micro"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.self_link
    access_config {

    }
  }

  tags = ["allow-ssh-tag"]

  metadata = {
    ssh-keys = "usuario:${file("/Users/usuario/.ssh/id_ed25519.pub")}"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "usuario"
      private_key = file("/Users/usuario/.ssh/id_ed25519")
      host        = self.network_interface[0].access_config[0].nat_ip
    }

    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y mysql-server",
      "sudo systemctl start mysql",
      "sudo systemctl enable mysql",
      "sudo mysql -e 'CREATE DATABASE minha_base_de_dados;'",
      "sudo mysql -e 'CREATE USER \"usuario\"@\"%\" IDENTIFIED BY \"senha\";'",
      "sudo mysql -e 'GRANT ALL PRIVILEGES ON minha_base_de_dados.* TO \"usuario\"@\"%\";'",
      "sudo mysql -e 'FLUSH PRIVILEGES;'"
    ]
  }
}

resource "google_secret_manager_secret" "github_token_secret" {
  project = module.prod_env.env_variables.project_id
  secret_id = "github-token"

  replication {
    auto {
      
    }
  }
}

resource "google_secret_manager_secret_version" "github_token_secret_version" {
  secret = google_secret_manager_secret.github_token_secret.id
  secret_data = module.prod_env.env_variables.github_pat
}

data "google_iam_policy" "servceagent_secretAccessor" {
  binding {
    role = "roles/secretmanager.secretAccessor"
    members = ["serviceAccount:service-${module.prod_env.env_variables.project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"]
  }
}

resource "google_secret_manager_secret_iam_policy" "policy" {
  project = google_secret_manager_secret.github_token_secret.project
  secret_id = google_secret_manager_secret.github_token_secret.secret_id
  policy_data = data.google_iam_policy.servceagent_secretAccessor.policy_data
}

resource "google_cloudbuildv2_connection" "wishlist_connection"{
  project = "lista-de-compras-438114"
  location = "us-central1"
  name = "wishlist-connection"

  github_config {
    app_installation_id = module.prod_env.env_variables.instalation_id
    authorizer_credential {
      oauth_token_secret_version = google_secret_manager_secret_version.github_token_secret_version.id
    }
  }
  depends_on = [google_secret_manager_secret_iam_policy.policy]
}

resource "google_cloudbuildv2_repository" "wishlist_repo" {
  project = "lista-de-compras-438114"
  location = "us-central1"
  name = "market-list-wishlist-service"
  remote_uri = "https://github.com/funas-org/market-list-wishlist-service.git"
  parent_connection = google_cloudbuildv2_connection.wishlist_connection.id
}

resource "google_service_account" "cloudbuild_service_account" {
  account_id = "terraform-cloud-sa"
}

resource "google_project_iam_member" "act_as" {
  project = "lista-de-compras-438114"
  role = "roles/iam.serviceAccountUser"
  member = "serviceAccount:${google_service_account.cloudbuild_service_account.email}"
}

resource "google_project_iam_member" "logs_writer" {
  project = "lista-de-compras-438114"
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_service_account.email}"
}

resource "google_cloudbuild_trigger" "wishlist_trigger" {
  location = "us-central1"
  service_account = google_service_account.cloudbuild_service_account.id

  trigger_template {
    branch_name = "main"
    repo_name = google_cloudbuildv2_repository.wishlist_repo.name
  }

  depends_on = [
    google_project_iam_member.act_as,
    google_project_iam_member.logs_writer
   ]

  filename = "cloudbuild.yaml"
}
 