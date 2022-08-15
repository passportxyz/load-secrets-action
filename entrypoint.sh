#!/bin/bash
# shellcheck disable=SC2046,SC2001,SC2086
set -e

readonly CONNECT="CONNECT"
readonly SERVICE_ACCOUNT="SERVICE_ACCOUNT"

auth_type=$CONNECT
managed_variables_var="OP_MANAGED_VARIABLES"
IFS=','

# Unset all secrets managed by 1Password if `unset-previous` is set.
unset_prev_secrets() {
  if [ "$INPUT_UNSET_PREVIOUS" == "true" ]; then
    echo "Unsetting previous values..."

    # Find environment variables that are managed by 1Password.
    for env_var in "${managed_variables[@]}"; do
      echo "Unsetting $env_var"
      unset $env_var

      echo "$env_var=" >> $GITHUB_ENV

      # Keep the masks, just in case.
    done

    managed_variables=()
  fi
}

# Install op-cli
install_op_cli() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    curl -sSfLo op.zip "https://cache.agilebits.com/dist/1P/op2/pkg/v2.6.0-beta.06/op_linux_amd64_v2.6.0-beta.06.zip"
    unzip -od ./op op.zip && rm op.zip
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    curl -sSfLo op.tar.gz "https://cache.agilebits.com/dist/1P/op2/pkg/v2.6.0-beta.06/1password-cli_v2.6.0-beta.06_darwin_amd64.tar.gz"
    mkdir ./op && tar -xf op.tar.gz -C ./op
  fi
}

populating_secret() {
  ref=$(printenv $1)

  echo "Populating variable: $1"
  secret_value=$(op read $ref)

  if [ -z "$secret_value" ]; then
    echo "Could not find or access secret $ref"
    exit 1
  fi

  # Register a mask for the secret to prevent accidental log exposure.
  # To support multiline secrets, escape percent signs and add a mask per line.
  escaped_mask_value=$(echo "$secret_value" | sed -e 's/%/%25/g')
  IFS=$'\n'
  for line in $escaped_mask_value; do
    if [ "${#line}" -lt 3 ]; then
      # To avoid false positives and unreadable logs, omit mask for lines that are too short.
      continue
    fi
    echo "::add-mask::$line"
  done
  unset IFS

  if [ "$INPUT_EXPORT_ENV" == "true" ]; then
    # To support multiline secrets, we'll use the heredoc syntax to populate the environment variables.
    # As the heredoc identifier, we'll use a randomly generated 64-character string,
    # so that collisions are practically impossible.
    random_heredoc_identifier=$(openssl rand -hex 16)

    {
      # Populate env var, using heredoc syntax with generated identifier
      echo "$env_var<<${random_heredoc_identifier}"
      echo "$secret_value"
      echo "${random_heredoc_identifier}"
    } >> $GITHUB_ENV
    echo "GITHUB_ENV: $(cat $GITHUB_ENV)"

  else
    # Prepare the secret_value to be outputed properly (especially multiline secrets)
    secret_value=$(echo "$secret_value" | awk -v ORS='%0A' '1')

    echo "::set-output name=$env_var::$secret_value"
  fi

  managed_variables+=("$env_var")
}

# Load environment variables using op cli. Iterate over them to find 1Password references, load the secret values,
# and make them available as environment variables in the next steps.
extract_using_service_account() {
  IFS=$'\n'
  for env_var in $(op env ls); do
    populating_secret $env_var
  done
}

# Load environment variables using connect service. Iterate over hem to find 1Password references, load the secret values,
# and make them available as environment variables in the next steps.
extract_using_connect() {
  IFS=$'\n'

  for possible_ref in $(printenv | grep "=op://" | grep -v "^#"); do
    env_var=$(echo "$possible_ref" | cut -d '=' -f1)
    populating_secret $env_var
  done
}

read -r -a managed_variables <<< "$(printenv $managed_variables_var)"

if [ -z "$OP_CONNECT_TOKEN" ] || [ -z "$OP_CONNECT_HOST" ]; then
  if [ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]; then
    echo "(\$OP_CONNECT_TOKEN and \$OP_CONNECT_HOST) or \$OP_SERVICE_ACCOUNT_TOKEN must be set"
    exit 1
  fi

  auth_type=$SERVICE_ACCOUNT
fi

printf "Authenticated with %s \n" $auth_type

unset_prev_secrets
install_op_cli

if [ "$auth_type" == "$SERVICE_ACCOUNT" ]; then
  extract_using_service_account
elif [ "$auth_type" == "$CONNECT" ]; then
  extract_using_connect
fi

unset IFS
# Add extra env var that lists which secrets are managed by 1Password so that in a later step
# these can be unset again.
managed_variables_str=$(IFS=','; echo "${managed_variables[*]}")
echo "$managed_variables_var=$managed_variables_str" >> $GITHUB_ENV
