# ---------------------------------------------------------------------------
# Notifications + alerting. The function logs each check to Application Insights
# as "uptime_result <json>". KQL scheduled-query alerts run over those traces
# (site-down, high-latency, SSL-expiry) and route to an action group that emails
# / texts the operator. This is the Azure analog to CloudWatch custom metrics +
# metric alarms + SNS on the AWS build.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "uptime" {
  name                = "ag-${var.project}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "uptime"

  email_receiver {
    name                    = "operator-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  dynamic "sms_receiver" {
    for_each = var.alert_sms != "" ? [1] : []
    content {
      name         = "operator-sms"
      country_code = var.alert_sms_country
      phone_number = var.alert_sms
    }
  }
}

locals {
  parse_results = <<-KQL
    traces
    | where message has "uptime_result"
    | extend payload = parse_json(tostring(extract("uptime_result (.*)$", 1, message)))
  KQL
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "site_down" {
  name                    = "alert-${var.project}-site-down"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  description             = "${var.check_url} failed 2 consecutive checks"
  severity                = 1
  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  auto_mitigation_enabled = true

  criteria {
    query                   = "${local.parse_results}| where toint(payload.is_healthy) == 0"
    time_aggregation_method = "Count"
    threshold               = 2
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.uptime.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "high_latency" {
  name                    = "alert-${var.project}-high-latency"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  description             = "${var.check_url} average latency exceeded ${var.latency_threshold_ms} ms"
  severity                = 2
  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true

  criteria {
    query                   = "${local.parse_results}| summarize avg_latency = avg(toint(payload.latency_ms))"
    time_aggregation_method = "Average"
    metric_measure_column   = "avg_latency"
    threshold               = var.latency_threshold_ms
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.uptime.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ssl_expiry" {
  name                    = "alert-${var.project}-ssl-expiry"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  description             = "${var.check_url} SSL certificate expires within 7 days"
  severity                = 2
  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT1H"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true

  criteria {
    query                   = "${local.parse_results}| where toint(payload.ssl_days_remaining) >= 0 and toint(payload.ssl_days_remaining) <= 7"
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.uptime.id]
  }
}

# --- Workbook dashboard ----------------------------------------------------

resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "uptime" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "Uptime Monitor"
  source_id           = lower(azurerm_application_insights.main.id)

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type    = 1
        content = { json = "# Website Uptime Monitor\n${var.check_url}" }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          query         = "traces | where message has 'uptime_result' | extend p = parse_json(tostring(extract('uptime_result (.*)$', 1, message))) | summarize health = min(toint(p.is_healthy)) by bin(timestamp, 5m) | render timechart"
          size          = 0
          title         = "Site Health (1 = up, 0 = down)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          visualization = "timechart"
        }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          query         = "traces | where message has 'uptime_result' | extend p = parse_json(tostring(extract('uptime_result (.*)$', 1, message))) | summarize latency_ms = avg(toint(p.latency_ms)) by bin(timestamp, 5m) | render timechart"
          size          = 0
          title         = "Response Latency (ms)"
          timeContext   = { durationMs = 86400000 }
          queryType     = 0
          visualization = "timechart"
        }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          query         = "traces | where message has 'uptime_result' | extend p = parse_json(tostring(extract('uptime_result (.*)$', 1, message))) | summarize ssl_days = min(toint(p.ssl_days_remaining)) by bin(timestamp, 1h) | render timechart"
          size          = 0
          title         = "SSL Days Remaining"
          timeContext   = { durationMs = 604800000 }
          queryType     = 0
          visualization = "timechart"
        }
      }
    ]
    isLocked = false
  })
}
