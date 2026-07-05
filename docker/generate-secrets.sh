#!/bin/sh
# Generate secrets on first startup.
# Writes to .env file if values don't exist yet.

ENV_FILE="${1:-.env}"

# ---- SECRET_KEY_BASE ----
if grep -q "^SECRET_KEY_BASE=." "$ENV_FILE" 2>/dev/null && \
   ! grep -q "^SECRET_KEY_BASE=changeme" "$ENV_FILE" 2>/dev/null; then
  echo "[secrets] SECRET_KEY_BASE already set in $ENV_FILE, skipping."
else
  echo "[secrets] Generating SECRET_KEY_BASE..."
  SECRET=$(openssl rand -base64 64 | tr -d '\n')
  if grep -q "^SECRET_KEY_BASE=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET|" "$ENV_FILE"
  else
    echo "" >> "$ENV_FILE"
    echo "# Phoenix secret key base (auto-generated, do not delete)" >> "$ENV_FILE"
    echo "SECRET_KEY_BASE=$SECRET" >> "$ENV_FILE"
  fi
  echo "[secrets] SECRET_KEY_BASE generated and saved to $ENV_FILE"
fi

# ---- CrowdSec → Caddy bouncer key ----
if grep -q "^CROWDSEC_BOUNCER_CADDY_KEY=." "$ENV_FILE" 2>/dev/null; then
  echo "[secrets] CROWDSEC_BOUNCER_CADDY_KEY already set in $ENV_FILE, skipping."
else
  echo "[secrets] Generating CROWDSEC_BOUNCER_CADDY_KEY..."
  BOUNCER_KEY=$(openssl rand -hex 32)
  if grep -q "^CROWDSEC_BOUNCER_CADDY_KEY=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^CROWDSEC_BOUNCER_CADDY_KEY=.*|CROWDSEC_BOUNCER_CADDY_KEY=$BOUNCER_KEY|" "$ENV_FILE"
  else
    echo "" >> "$ENV_FILE"
    echo "# CrowdSec bouncer key (auto-generated, do not delete)" >> "$ENV_FILE"
    echo "CROWDSEC_BOUNCER_CADDY_KEY=$BOUNCER_KEY" >> "$ENV_FILE"
  fi
  echo "[secrets] CROWDSEC_BOUNCER_CADDY_KEY generated and saved to $ENV_FILE"
fi

# ---- At-rest encryption keys ----
# MESSAGE_ENCRYPTION_KEY encrypts DM content; DATA_ENCRYPTION_KEY encrypts
# actor private keys, 2FA secrets, and emails. Losing either makes the
# corresponding data unrecoverable, so once set they are never regenerated.
for var in MESSAGE_ENCRYPTION_KEY DATA_ENCRYPTION_KEY; do
  if grep -q "^${var}=." "$ENV_FILE" 2>/dev/null; then
    echo "[secrets] ${var} already set in $ENV_FILE, skipping."
  else
    echo "[secrets] Generating ${var}..."
    VALUE=$(openssl rand -base64 32 | tr -d '\n')
    if grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^${var}=.*|${var}=$VALUE|" "$ENV_FILE"
    else
      echo "" >> "$ENV_FILE"
      echo "# At-rest encryption key (auto-generated, do NOT delete or rotate casually)" >> "$ENV_FILE"
      echo "${var}=$VALUE" >> "$ENV_FILE"
    fi
    echo "[secrets] ${var} generated and saved to $ENV_FILE"
  fi
done

# ---- Instance actor keys ----
if grep -q "^INSTANCE_PUBLIC_KEY=." "$ENV_FILE" 2>/dev/null; then
  echo "[keys] Instance keys already exist in $ENV_FILE, skipping generation."
  exit 0
fi

echo "[keys] Generating instance actor RSA keypair..."

# Generate 2048-bit RSA key
PRIVATE_KEY=$(openssl genrsa 2048 2>/dev/null)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | openssl rsa -pubout 2>/dev/null)

# Base64 encode (single line, no wrapping)
PRIVATE_B64=$(echo "$PRIVATE_KEY" | base64 -w 0)
PUBLIC_B64=$(echo "$PUBLIC_KEY" | base64 -w 0)

# Append to .env
echo "" >> "$ENV_FILE"
echo "# Instance actor RSA keypair (auto-generated, do not delete)" >> "$ENV_FILE"
echo "INSTANCE_PUBLIC_KEY=$PUBLIC_B64" >> "$ENV_FILE"
echo "INSTANCE_PRIVATE_KEY=$PRIVATE_B64" >> "$ENV_FILE"

echo "[keys] Instance keys generated and saved to $ENV_FILE"
