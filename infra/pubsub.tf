resource "google_pubsub_topic" "pedidos" {
  name = "${var.prefijo}-pedidos"

  depends_on = [google_project_service.apis]
}

# El backend puede publicar en este tema y en ningún otro.
resource "google_pubsub_topic_iam_member" "backend_publica" {
  topic  = google_pubsub_topic.pedidos.name
  role   = "roles/pubsub.publisher"
  member = google_service_account.backend.member
}

resource "google_service_account" "cocina" {
  account_id   = "${var.prefijo}-cocina"
  display_name = "Cocina de la cafetería"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "cocina_firestore" {
  project = var.proyecto
  role    = "roles/datastore.user"
  member  = google_service_account.cocina.member
}

resource "google_cloud_run_v2_service" "cocina" {
  name                = "${var.prefijo}-cocina"
  location            = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.cocina.email

    scaling {
      max_instance_count = var.max_instancias_cocina
    }

    # Tantas peticiones a la vez como hilos tiene gunicorn en la cocina.
    max_instance_request_concurrency = 8

    containers {
      image = var.imagen_cocina

      env {
        name  = "BASE_DATOS"
        value = google_firestore_database.cafeteria.name
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.cocina_firestore,
  ]
}

data "google_project" "actual" {}

locals {
  agente_pubsub = "serviceAccount:service-${data.google_project.actual.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_service_account" "invocador" {
  account_id   = "${var.prefijo}-invocador"
  display_name = "Pub/Sub invoca a la cocina"

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "invocador_cocina" {
  name     = google_cloud_run_v2_service.cocina.name
  location = google_cloud_run_v2_service.cocina.location
  role     = "roles/run.invoker"
  member   = google_service_account.invocador.member
}

resource "google_service_account_iam_member" "pubsub_firma_tokens" {
  service_account_id = google_service_account.invocador.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.agente_pubsub

  # El agente de Pub/Sub aparece cuando se usa la API por primera vez.
  depends_on = [google_pubsub_topic.pedidos]
}

resource "google_pubsub_subscription" "cocina" {
  name  = "${var.prefijo}-cocina"
  topic = google_pubsub_topic.pedidos.id

  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "60s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.muertos.id
    max_delivery_attempts = 5
  }

  push_config {
    push_endpoint = google_cloud_run_v2_service.cocina.uri

    oidc_token {
      service_account_email = google_service_account.invocador.email
      audience              = google_cloud_run_v2_service.cocina.uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.invocador_cocina,
    google_service_account_iam_member.pubsub_firma_tokens,
  ]
}

# ---------- Mensajes muertos ----------

resource "google_pubsub_topic" "muertos" {
  name = "${var.prefijo}-muertos"

  depends_on = [google_project_service.apis]
}

# Sin esta suscripción, lo que llegue al tema de muertos se pierde.
resource "google_pubsub_subscription" "muertos" {
  name  = "${var.prefijo}-muertos"
  topic = google_pubsub_topic.muertos.id
}

# El agente de Pub/Sub publica en el tema de muertos los mensajes que se rinden.
resource "google_pubsub_topic_iam_member" "agente_publica_muertos" {
  topic  = google_pubsub_topic.muertos.name
  role   = "roles/pubsub.publisher"
  member = local.agente_pubsub
}

# El agente de Pub/Sub confirma el mensaje en la suscripción de la cocina
# después de moverlo, para que no siga ahí.
resource "google_pubsub_subscription_iam_member" "agente_suscribe_cocina" {
  subscription = google_pubsub_subscription.cocina.name
  role         = "roles/pubsub.subscriber"
  member       = local.agente_pubsub
}