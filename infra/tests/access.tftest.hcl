# Plan-only tests with a mocked provider: no Cloudflare credentials, no API calls. `just check`
# runs them with `tofu test`.

mock_provider "cloudflare" {}

variables {
  account_id     = "00000000000000000000000000000000"
  zone_id        = "11111111111111111111111111111111"
  domain         = "example.org"
  allowed_emails = ["avery@example.org"]
}

run "every_hostname_sits_behind_access" {
  command = plan

  assert {
    condition     = output.hostnames == tolist(["beszel.example.org", "mlflow.example.org"])
    error_message = "the tunnel must serve exactly the default services, mlflow and beszel."
  }

  # A hostname in the ingress without an Access app would be open to anyone, and MLflow has no login.
  assert {
    condition = alltrue([
      for rule in cloudflare_zero_trust_tunnel_cloudflared_config.node.config.ingress :
      contains([for app in cloudflare_zero_trust_access_application.node : app.domain], rule.hostname)
      if rule.hostname != null
    ])
    error_message = "every ingress hostname must have an Access application."
  }

  assert {
    condition     = toset([for app in cloudflare_zero_trust_access_application.node : app.domain]) == toset(output.hostnames)
    error_message = "every DNS record must have an Access application."
  }

  assert {
    condition     = alltrue([for app in cloudflare_zero_trust_access_application.node : length(app.policies) == 1])
    error_message = "each Access application must carry the allowed-emails policy and nothing else."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_policy.allowed_emails.decision == "allow" &&
      [for rule in cloudflare_zero_trust_access_policy.allowed_emails.include : rule.email.email] == ["avery@example.org"]
    )
    error_message = "the policy must allow only the listed emails."
  }
}

run "ingress_ends_in_a_404" {
  command = plan

  # If the catch-all stops being last, unknown hostnames reach whichever origin follows it.
  assert {
    condition     = reverse(cloudflare_zero_trust_tunnel_cloudflared_config.node.config.ingress)[0].service == "http_status:404"
    error_message = "the last ingress rule must be the http_status:404 catch-all."
  }

  assert {
    condition = alltrue([
      for rule in cloudflare_zero_trust_tunnel_cloudflared_config.node.config.ingress :
      can(regex("^http://127\\.0\\.0\\.1:[0-9]{1,5}/?$", rule.service)) if rule.hostname != null
    ])
    error_message = "the tunnel may only reach services on this host's loopback."
  }
}

run "refuses_an_empty_email_list" {
  command = plan

  variables {
    allowed_emails = []
  }

  expect_failures = [var.allowed_emails]
}

run "refuses_a_service_off_loopback" {
  command = plan

  variables {
    services = { mlflow = "http://0.0.0.0:5000" }
  }

  expect_failures = [var.services]
}

# 127.0.0.1:1 is the userinfo here; the request goes to 10.0.0.5.
run "refuses_userinfo_that_looks_like_loopback" {
  command = plan

  variables {
    services = { mlflow = "http://127.0.0.1:1@10.0.0.5:80" }
  }

  expect_failures = [var.services]
}

# localhost may resolve to ::1 or to anything /etc/hosts says.
run "refuses_localhost" {
  command = plan

  variables {
    services = { mlflow = "http://localhost:5000" }
  }

  expect_failures = [var.services]
}
