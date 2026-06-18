# ---------------------------------------------------------------------------
# Serverless uptime monitor. A timer-triggered Python Function App checks the
# target URL every 5 minutes (HTTP status, content, SSL expiry, with one retry),
# logs each result to Cosmos DB (90-day TTL) and to Application Insights, where
# KQL scheduled-query alerts drive the notifications.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.project}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "other"
}

# --- Cosmos DB (serverless, SQL API, 90-day TTL) ---------------------------

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-${var.project}-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "uptime"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "logs" {
  name                  = "logs"
  resource_group_name   = azurerm_resource_group.main.name
  account_name          = azurerm_cosmosdb_account.main.name
  database_name         = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths   = ["/check_id"]
  partition_key_version = 2

  # 90 days, mirroring the DynamoDB TTL on the AWS build.
  default_ttl = 7776000
}

# --- Function App ----------------------------------------------------------

resource "azurerm_storage_account" "fn" {
  name                            = "st${replace(var.project, "-", "")}${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "deployments" {
  name                  = "deployments"
  storage_account_name  = azurerm_storage_account.fn.name
  container_access_type = "private"
}

resource "azurerm_service_plan" "fn" {
  name                = "asp-${var.project}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "uptime" {
  name                = "func-${var.project}-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.fn.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.fn.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.fn.primary_access_key

  runtime_name           = "python"
  runtime_version        = "3.11"
  instance_memory_in_mb  = 2048
  maximum_instance_count = 40

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  app_settings = {
    COSMOS_ENDPOINT  = azurerm_cosmosdb_account.main.endpoint
    COSMOS_DATABASE  = azurerm_cosmosdb_sql_database.main.name
    COSMOS_CONTAINER = azurerm_cosmosdb_sql_container.logs.name
    CHECK_URL        = var.check_url
    CONTENT_CHECK    = var.content_check
    SSL_WARN_DAYS    = "30"
    SSL_ALERT_DAYS   = "7"
  }
}

# Cosmos data-plane access for the function's managed identity (no keys).
# 00000000-...-000000000002 is the built-in "Cosmos DB Built-in Data Contributor".
resource "azurerm_cosmosdb_sql_role_assignment" "fn" {
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_function_app_flex_consumption.uptime.identity[0].principal_id
  scope               = azurerm_cosmosdb_account.main.id
}
