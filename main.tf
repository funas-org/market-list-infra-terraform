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
  project = module.prod_env.env_variables.project_id
  region  = "us-central1"
  zone    = "us-central1-c"
}

// Cria a rede e a regra de firewall para permitir o acesso SSH
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

// Cria a instância com o MySQL e cria o banco de dados
resource "google_compute_instance" "vm_instance" {
  depends_on   = [google_compute_firewall.allow_ssh]
  name         = "lista-de-compras"
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
      "sudo mysql -e 'CREATE DATABASE ${module.prod_env.env_variables.DB_NAME};'",
      "sudo mysql -e 'CREATE USER \"${module.prod_env.env_variables.DB_USER}\"@\"%\" IDENTIFIED BY \"${module.prod_env.env_variables.DB_PASSWORD}\";'",
      "sudo mysql -e 'GRANT ALL PRIVILEGES ON ${module.prod_env.env_variables.DB_NAME}.* TO \"${module.prod_env.env_variables.DB_USER}\"@\"%\";'",
      "sudo mysql -e 'FLUSH PRIVILEGES;'"
    ]
  }
}

// Cria a secret relacionada ao github token
resource "google_secret_manager_secret" "github_token_secret" {
  project = module.prod_env.env_variables.project_id
  secret_id = "github-token"

  replication {
    auto {
      
    }
  }
}

// Cria a versao com o valor da secret usando o PAT do github
resource "google_secret_manager_secret_version" "github_token_secret_version" {
  secret = google_secret_manager_secret.github_token_secret.id
  secret_data = module.prod_env.env_variables.github_pat
}

// Cria a politica de acesso a secret
data "google_iam_policy" "serviceagent_secretAccessor" {
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

// Habilitando os serviços necessários dentro do GCP
resource "google_project_service" "artifact_registry" {
  project = module.prod_env.env_variables.project_id
  service = "artifactregistry.googleapis.com"
}

resource "google_project_service" "run" {
  project = module.prod_env.env_variables.project_id
  service = "run.googleapis.com"
}

// Cria o repositório no Artifact Registry
resource "google_artifact_registry_repository" "lista_de_compras" {
  location = "us-central1"
  format = "DOCKER"
  project = google_project_service.artifact_registry.project
  repository_id = "lista"
}

// Cria a conexão com o github
resource "google_cloudbuildv2_connection" "wishlist_connection"{
  project = module.prod_env.env_variables.project_id
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

// Cria o repositório no Cloud Build referenciando o repositório do github
resource "google_cloudbuildv2_repository" "wishlist_repo" {
  project = module.prod_env.env_variables.project_id
  location = "us-central1"
  name = "market-list-wishlist-service"
  remote_uri = "https://github.com/funas-org/market-list-wishlist-service.git"
  parent_connection = google_cloudbuildv2_connection.wishlist_connection.id
}

// Cria a conta de serviço para o Cloud Build e adiciona as permissões necessárias
resource "google_service_account" "cloudbuild_service_account" {
  account_id = "terraform-cloud-sa"
}

resource "google_project_iam_member" "act_as" {
  project = module.prod_env.env_variables.project_id
  role = "roles/iam.serviceAccountUser"
  member = "serviceAccount:${google_service_account.cloudbuild_service_account.email}"
}

resource "google_project_iam_member" "logs_writer" {
  project = module.prod_env.env_variables.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_service_account.email}"
}

resource "google_project_iam_member" "cloudbuild_trigger" {
  project = module.prod_env.env_variables.project_id
  role    = "roles/cloudbuild.integrationsEditor"
  member  = "serviceAccount:${google_service_account.cloudbuild_service_account.email}"
}

// Cria o trigger para o Cloud Build
resource "google_cloudbuild_trigger" "wishlist_trigger" {
  name = "wishlist-trigger"
  description = "Trigger para buildar e deployar a aplicação ao subir na main do github"
  location = "us-central1"
  project = module.prod_env.env_variables.project_id
  service_account = "projects/${module.prod_env.env_variables.project_id}/serviceAccounts/${google_service_account.cloudbuild_service_account.email}"

  github {
    owner = "funas-org"
    name = google_cloudbuildv2_repository.wishlist_repo.name
    push {
      branch = "main"
    }
  }

  depends_on = [
    google_project_iam_member.act_as,
    google_project_iam_member.logs_writer,
    google_cloudbuildv2_repository.wishlist_repo,
  ]

  build {
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["build", "-t", "us-central1-docker.pkg.dev/${module.prod_env.env_variables.project_id}/${google_artifact_registry_repository.lista_de_compras.repository_id}/${google_artifact_registry_repository.lista_de_compras.name}:latest", "."]
    }

    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["push", "us-central1-docker.pkg.dev/${module.prod_env.env_variables.project_id}/${google_artifact_registry_repository.lista_de_compras.repository_id}/list-de-compras:latest"]
    }

    step {
      name = "gcr.io/google.com/cloudsdktool/cloud-sdk"
      args = [
        "gcloud",
        "run",
        "deploy",
        "meu-cloud-run",
        "--image",
        "us-central1-docker.pkg.dev/${module.prod_env.env_variables.project_id}/${google_artifact_registry_repository.lista_de_compras.repository_id}/lista-de-compras:latest",
        "--region",
        "us-central1",
        "--platform",
        "managed",
        "--allow-unauthenticated"
      ]
    }
    # Aqui estamos especificando para nao logar nada na pipeline, mas podemos mudar isso
    options {
      logging = "NONE"
    }
  }
}
 