variable "account_id" {
  type        = string
  description = "Cloudflare account ID that holds the zone of var.domain."
}

variable "zone_id" {
  type        = string
  description = "Zone ID of var.domain."
}

variable "domain" {
  type        = string
  description = "Apex domain the hostnames live under: <subdomain>.<domain> for each of var.services."
}

variable "allowed_emails" {
  type        = list(string)
  description = "Email addresses Cloudflare Access lets through, with a one-time PIN."
  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "Set at least one email, or Access locks everyone out."
  }
}

variable "services" {
  type        = map(string)
  description = "Subdomain to service on this host. Each one gets an ingress rule, a DNS record and an Access application."
  # beszel goes when the node's host telemetry moves to the monitoring spoke.
  default = {
    mlflow = "http://127.0.0.1:5000"
    beszel = "http://127.0.0.1:8090"
  }
  validation {
    condition     = alltrue([for service in values(var.services) : startswith(service, "http://127.0.0.1:")])
    error_message = "Services must listen on this host's 127.0.0.1, so Access stays the only way in."
  }
}
