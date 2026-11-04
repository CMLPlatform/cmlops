# A remotely managed Cloudflare tunnel from this node to its own web UIs, each behind Cloudflare
# Access with an email one-time PIN. The connector only dials out; see README.md.

resource "cloudflare_zero_trust_tunnel_cloudflared" "node" {
  account_id = var.account_id
  name       = "cml-node-tools"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "node" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.node.id

  config = {
    ingress = concat(
      [for sub, service in var.services : {
        hostname = "${sub}.${var.domain}"
        service  = service
        # cloudflared checks the Access token itself, so a request reaches the origin only through
        # this hostname's Access application, even if that application is loosened or deleted.
        origin_request = {
          access = {
            required  = true
            team_name = var.team_name
            aud_tag   = [cloudflare_zero_trust_access_application.node[sub].aud]
          }
        }
      }],
      # Cloudflare requires a terminal rule; anything else gets a 404, never an origin.
      [{ service = "http_status:404" }],
    )
  }
}

resource "cloudflare_dns_record" "node" {
  for_each = var.services
  zone_id  = var.zone_id
  # Provider v5 wants the full hostname (terraform-provider-cloudflare#5620).
  name    = "${each.key}.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.node.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# MLflow has no login of its own, so this is its only gate.
resource "cloudflare_zero_trust_access_application" "node" {
  for_each   = var.services
  account_id = var.account_id
  name       = "${each.key} (cml node)"
  domain     = "${each.key}.${var.domain}"
  type       = "self_hosted"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.allowed_emails.id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "allowed_emails" {
  account_id       = var.account_id
  name             = "node tools: allowed emails"
  decision         = "allow"
  session_duration = "24h"

  include = [for email in var.allowed_emails : {
    email = { email = email }
  }]
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "node" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.node.id
}
