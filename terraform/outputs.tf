output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.uptime.name
}

output "cosmos_account" {
  value = azurerm_cosmosdb_account.main.name
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "action_group_name" {
  value = azurerm_monitor_action_group.uptime.name
}

output "workbook_url" {
  description = "Portal link to the uptime workbook"
  value       = "https://portal.azure.com/#@/resource${azurerm_application_insights_workbook.uptime.id}"
}
