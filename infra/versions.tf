terraform {
  required_version = ">= 1.8"

  # The state holds the tunnel secret, so it stays outside the clone: `just tofu init` sets the
  # path to $CMLOPS_STATE/terraform.tfstate.
  backend "local" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Authenticates with CLOUDFLARE_API_TOKEN from the environment; see README.md.
provider "cloudflare" {}
