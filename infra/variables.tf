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

variable "team_name" {
  type        = string
  description = "The Zero Trust team name: <team_name>.cloudflareaccess.com, shown in the Zero Trust dashboard's settings."
}

variable "services" {
  type        = map(string)
  description = "Subdomain to service on this host. Each one gets an ingress rule, a DNS record and an Access application. The mlflow default matches CMLOPS_MLFLOW_PORT's default of 5000; another port there means overriding this map in terraform.tfvars."
  default = {
    mlflow = "http://127.0.0.1:5000"
  }
  validation {
    # A prefix check would pass http://127.0.0.1:1@10.0.0.5, whose host is 10.0.0.5.
    condition     = alltrue([for service in values(var.services) : can(regex("^http://127\\.0\\.0\\.1:[0-9]{1,5}/?$", service))])
    error_message = "Each service must be http://127.0.0.1:<port>, so Access stays the only way in."
  }
}
