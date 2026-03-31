#!/usr/bin/env bash
set -euo pipefail
# set -ex

# Usage:
#   ./manage.sh start                              - Start EC2 and update Route53
#   ./manage.sh stop                               - Stop EC2
#   ./manage.sh setup  --key-file ~/.ssh/my-key.pem  - First-time EC2 setup (docker, nginx, certbot)
#   ./manage.sh deploy --key-file ~/.ssh/my-key.pem  - Upload config files and start containers
#   ./manage.sh start  --profile myprofile          - Use specific AWS profile

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ACTION=""
PROFILE=""
KEYFILE=""

usage() {
  echo "Usage: $0 {start|stop|setup|deploy} [--profile NAME] [--key-file PATH]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    start | stop | setup | deploy)
      ACTION="$1"
      shift
      ;;
    --profile | -Profile)
      [[ $# -ge 2 ]] || usage
      PROFILE="$2"
      shift 2
      ;;
    --key-file | -KeyFile)
      [[ $# -ge 2 ]] || usage
      KEYFILE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$ACTION" ]] || usage

if [[ -n "$PROFILE" ]]; then
  export AWS_PROFILE="$PROFILE"
  echo "AWS profile: $PROFILE"
  # shellcheck disable=SC2046
  eval "$(aws configure export-credentials --profile "$PROFILE" --format env)" || {
    echo "Failed to get credentials. Run 'aws login' first and try again." >&2
    exit 1
  }
fi

get_tf_output() {
  local key=$1
  local val
  if ! val=$(terraform -chdir=infra output -raw "$key" 2>/dev/null); then
    echo "terraform output '$key' not found. Run 'infra/tf.sh apply' first." >&2
    exit 1
  fi
  if [[ -z "$val" ]]; then
    echo "terraform output '$key' not found. Run 'infra/tf.sh apply' first." >&2
    exit 1
  fi
  printf '%s' "$val"
}

get_instance_ip() {
  local id=$1
  local ip
  ip=$(aws ec2 describe-instances \
    --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  if [[ -z "$ip" || "$ip" == "None" ]]; then
    echo "EC2 is not running. Run './manage.sh start' first." >&2
    exit 1
  fi
  printf '%s' "$ip"
}

if [[ "$ACTION" == "start" ]]; then
  InstanceId=$(get_tf_output instance_id)
  HostedZoneId=$(get_tf_output hosted_zone_id)
  Domain=$(get_tf_output domain)
  OtelEp=$(terraform -chdir=infra output -raw otel_endpoint 2>/dev/null || true)
  GrafanaEp=$(terraform -chdir=infra output -raw grafana_url 2>/dev/null || true)
  OtelSub=${OtelEp#https://}
  OtelSub=${OtelSub%.$Domain}
  GrafanaSub=${GrafanaEp#https://}
  GrafanaSub=${GrafanaSub%.$Domain}

  echo "==> Starting EC2: $InstanceId"
  aws ec2 start-instances --instance-ids "$InstanceId" >/dev/null

  echo "==> Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$InstanceId"

  NewIp=$(aws ec2 describe-instances \
    --instance-ids "$InstanceId" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  echo "==> Public IP: $NewIp"

  TmpJson=$(mktemp)
  trap 'rm -f "$TmpJson"' EXIT

  for Sub in "$OtelSub" "$GrafanaSub"; do
    Fqdn="${Sub}.${Domain}"
    echo "==> Updating Route53: $Fqdn -> $NewIp"
    cat >"$TmpJson" <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$Fqdn",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "$NewIp"}]
    }
  }]
}
EOF
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HostedZoneId" \
      --change-batch "file://$TmpJson" >/dev/null
  done
  trap - EXIT
  rm -f "$TmpJson"

  echo ""
  echo "==> Done. DNS propagation may take up to 60 seconds."
  echo "    Grafana : https://${GrafanaSub}.${Domain}"
  echo "    OTel EP : https://${OtelSub}.${Domain}"

elif [[ "$ACTION" == "stop" ]]; then
  InstanceId=$(get_tf_output instance_id)
  echo "==> Stopping EC2: $InstanceId"
  aws ec2 stop-instances --instance-ids "$InstanceId" >/dev/null
  echo "==> Stopped."

elif [[ "$ACTION" == "setup" ]]; then
  InstanceId=$(get_tf_output instance_id)
  Domain=$(get_tf_output domain)
  OtelEp=$(get_tf_output otel_endpoint)
  GrafanaUrl=$(get_tf_output grafana_url)
  SshPort=$(get_tf_output ssh_port)
  OtelDomain=${OtelEp#https://}
  GrafanaDomain=${GrafanaUrl#https://}

  if [[ -z "$KEYFILE" ]]; then
    echo "Specify --key-file. Example: ./manage.sh setup --key-file ~/.ssh/my-key.pem" >&2
    exit 1
  fi

  Ip=$(get_instance_ip "$InstanceId")
  Email="admin@${Domain}"

  echo "==> EC2: $Ip (SSH port: $SshPort)"
  echo "==> OTel domain   : $OtelDomain"
  echo "==> Grafana domain: $GrafanaDomain"
  echo ""

  echo "==> Uploading setup.sh..."
  scp -i "$KEYFILE" -o StrictHostKeyChecking=no -P "$SshPort" setup.sh "ec2-user@${Ip}:/tmp/setup.sh"

  echo "==> Running setup (this may take a few minutes)..."
  ssh -i "$KEYFILE" -o StrictHostKeyChecking=no -p "$SshPort" "ec2-user@${Ip}" \
    "sudo bash /tmp/setup.sh $OtelDomain $GrafanaDomain $Email"

  echo ""
  echo "==> Setup complete. Run deploy next:"
  echo "    ./manage.sh deploy --key-file $KEYFILE"

elif [[ "$ACTION" == "deploy" ]]; then
  InstanceId=$(get_tf_output instance_id)
  OtelEp=$(get_tf_output otel_endpoint)
  GrafanaUrl=$(get_tf_output grafana_url)
  SshPort=$(get_tf_output ssh_port)
  OtelDomain=${OtelEp#https://}
  GrafanaDomain=${GrafanaUrl#https://}

  if [[ -z "$KEYFILE" ]]; then
    echo "Specify --key-file. Example: ./manage.sh deploy --key-file ~/.ssh/my-key.pem" >&2
    exit 1
  fi

  if [[ ! -f .env ]]; then
    echo ".env not found. Copy .env.example to .env and fill in the values." >&2
    exit 1
  fi
  if [[ ! -f otel.htpasswd ]]; then
    echo "otel.htpasswd not found. Create it with:" >&2
    echo "  docker run --rm httpd htpasswd -nbB claude 'your-password' > otel.htpasswd" >&2
    exit 1
  fi

  Ip=$(get_instance_ip "$InstanceId")

  echo "==> EC2: $Ip (SSH port: $SshPort)"
  echo "==> OTel domain   : $OtelDomain"
  echo "==> Grafana domain: $GrafanaDomain"
  echo ""

  echo "==> Uploading config files..."
  Target="ec2-user@${Ip}:/opt/claude-monitoring/"
  SshOpts=(-i "$KEYFILE" -o StrictHostKeyChecking=no -P "$SshPort")

  scp "${SshOpts[@]}" docker-compose.yml "$Target"
  scp "${SshOpts[@]}" .env "$Target"
  scp "${SshOpts[@]}" otelcol-config.yaml "$Target"
  scp "${SshOpts[@]}" otel.htpasswd "$Target"
  scp "${SshOpts[@]}" -r prometheus "$Target"
  ssh -i "$KEYFILE" -o StrictHostKeyChecking=no -p "$SshPort" "ec2-user@${Ip}" \
    'rm -rf /opt/claude-monitoring/grafana/'
  scp "${SshOpts[@]}" -r grafana "$Target"
  scp "${SshOpts[@]}" -r nginx "$Target"
  scp "${SshOpts[@]}" -r loki "$Target"

  echo "==> Configuring nginx..."
  # Match placeholders \${OTEL_DOMAIN} / \${GRAFANA_DOMAIN} in nginx.conf (same as PowerShell manage.ps1)
  ssh -i "$KEYFILE" -o StrictHostKeyChecking=no -p "$SshPort" "ec2-user@${Ip}" \
    "sed 's/\${OTEL_DOMAIN}/${OtelDomain}/g; s/\${GRAFANA_DOMAIN}/${GrafanaDomain}/g' /opt/claude-monitoring/nginx/nginx.conf | sudo tee /etc/nginx/conf.d/claude-monitoring.conf > /dev/null && sudo nginx -t && sudo systemctl reload nginx"

  echo "==> Starting and restarting containers..."
  ssh -i "$KEYFILE" -o StrictHostKeyChecking=no -p "$SshPort" "ec2-user@${Ip}" \
    'cd /opt/claude-monitoring && docker compose up -d && docker compose restart'

  echo ""
  echo "==> Deploy complete."
  echo "    Grafana : https://$GrafanaDomain"
  echo "    OTel EP : https://$OtelDomain"
fi
