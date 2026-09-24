#!/usr/bin/env bash

# This file is sourced by the run/setup wrappers. It reads only an allowlisted
# dotenv assignment and never evaluates the local .env as shell code.

load_root_dotenv_var() {
  local root="$1"
  local name="$2"
  local env_file="$root/.env"
  local value

  [[ -n "${!name:-}" || ! -f "$env_file" ]] && return 0

  value="$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=[[:space:]]*//p" "$env_file" | tail -n 1)"
  value="${value%$'\r'}"
  if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
    value="${value:1:-1}"
  elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
    value="${value:1:-1}"
  fi

  [[ -z "$value" || "$value" == \#* ]] && return 0
  printf -v "$name" '%s' "$value"
  export "$name"
}

load_litellm_upstream_env() {
  local root="$1"
  load_root_dotenv_var "$root" LITELLM_UPSTREAM_BASE_URL
  load_root_dotenv_var "$root" LITELLM_UPSTREAM_API_KEY
}

load_claude_oauth_env() {
  load_root_dotenv_var "$1" CLAUDE_CODE_OAUTH_TOKEN
}
