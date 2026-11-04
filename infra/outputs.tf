output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.node.id
}

output "hostnames" {
  value = sort([for record in cloudflare_dns_record.node : record.name])
}

output "tunnel_token" {
  description = "The connector's credential. `just token` writes it to the token file."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.node.token
  sensitive   = true
}
