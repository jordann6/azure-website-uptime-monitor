variable "location" {
  type        = string
  description = "Azure region for all resources"
  default     = "eastus2"
}

variable "project" {
  type        = string
  description = "Name prefix applied to all resources"
  default     = "uptime-monitor"
}

variable "check_url" {
  type        = string
  description = "URL to monitor"
  default     = "https://jordandesigns.io"
}

variable "content_check" {
  type        = string
  description = "Substring to verify in the response body. Empty disables the check."
  default     = ""
}

variable "alert_email" {
  type        = string
  description = "Email address for downtime / SSL alerts"
  default     = "jordandn6@outlook.com"
}

variable "alert_sms" {
  type        = string
  description = "Phone number (no +, with country code) for SMS alerts. Empty disables SMS."
  default     = ""
}

variable "alert_sms_country" {
  type        = string
  description = "Country code for the SMS receiver (e.g. 1 for US)"
  default     = "1"
}

variable "latency_threshold_ms" {
  type        = number
  description = "Average latency (ms) over the window that trips the high-latency alert"
  default     = 3000
}
