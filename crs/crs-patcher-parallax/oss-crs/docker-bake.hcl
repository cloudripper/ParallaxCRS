# =============================================================================
# CRC-Template Claude Code Patcher Docker Bake Configuration
# =============================================================================
#
# Builds the CRS base image with Claude Code CLI and Python dependencies.
#
# Usage:
#   docker buildx bake prepare
#   docker buildx bake --push prepare   # Push to registry
# =============================================================================

variable "REGISTRY" {
  # `localhost` makes an accidental `prepare --publish` fail without a local
  # registry instead of targeting the upstream Team Atlanta namespace. Override
  # explicitly when publishing an intentionally owned derived image.
  default = "localhost"
}

variable "VERSION" {
  default = "latest"
}

variable "CLAUDE_CODE_CLI_VERSION" {
  default = "2.1.168"
}

function "tags" {
  params = [name]
  result = [
    "${REGISTRY}/${name}:${VERSION}",
    "${REGISTRY}/${name}:latest",
    "${name}:latest"
  ]
}

# -----------------------------------------------------------------------------
# Groups
# -----------------------------------------------------------------------------

group "default" {
  targets = ["prepare"]
}

group "prepare" {
  targets = ["crs-patcher-claude-code-base"]
}

# -----------------------------------------------------------------------------
# Base Image
# -----------------------------------------------------------------------------

target "crs-patcher-claude-code-base" {
  context    = "."
  dockerfile = "oss-crs/base.Dockerfile"
  tags       = tags("crs-patcher-claude-code-base")
  args = {
    CLAUDE_CODE_CLI_VERSION = CLAUDE_CODE_CLI_VERSION
  }
}
