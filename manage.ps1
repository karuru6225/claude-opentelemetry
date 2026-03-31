#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('start', 'stop', 'setup', 'deploy')]
  [string]$Action,

  [string]$Profile = '',

  [string]$KeyFile = ''
)

# Usage:
#   .\manage.ps1 start                              - Start EC2 and update Route53
#   .\manage.ps1 stop                               - Stop EC2
#   .\manage.ps1 setup  -KeyFile ~/.ssh/my-key.pem  - First-time EC2 setup (docker, nginx, certbot)
#   .\manage.ps1 deploy -KeyFile ~/.ssh/my-key.pem  - Upload config files and start containers
#   .\manage.ps1 start  -Profile myprofile          - Use specific AWS profile

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Profile) {
  $env:AWS_PROFILE = $Profile
  Write-Host "AWS profile: $Profile"

  $credEnv = aws configure export-credentials --profile $Profile --format powershell
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get credentials. Run 'aws login' first and try again."
    exit 1
  }
  Invoke-Expression ($credEnv -join "`n")
}

function Get-TfOutput([string]$Key) {
  $val = terraform -chdir=infra output -raw $Key 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($val)) {
    Write-Error "terraform output '$Key' not found. Run 'infra\manage.ps1 apply' first."
    exit 1
  }
  return $val
}

function Get-InstanceIp([string]$InstanceId) {
  $ip = aws ec2 describe-instances `
    --instance-ids $InstanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' `
    --output text
  if ([string]::IsNullOrEmpty($ip) -or $ip -eq 'None') {
    Write-Error "EC2 is not running. Run '.\manage.ps1 start' first."
    exit 1
  }
  return $ip
}

if ($Action -eq 'start') {
  $InstanceId   = Get-TfOutput 'instance_id'
  $HostedZoneId = Get-TfOutput 'hosted_zone_id'
  $Domain       = Get-TfOutput 'domain'
  $OtelSub      = (terraform -chdir=infra output -raw otel_endpoint 2>$null) -replace 'https://', '' -replace "\.$Domain", ''
  $GrafanaSub   = (terraform -chdir=infra output -raw grafana_url 2>$null) -replace 'https://', '' -replace "\.$Domain", ''

  Write-Host "==> Starting EC2: $InstanceId"
  aws ec2 start-instances --instance-ids $InstanceId | Out-Null
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Write-Host '==> Waiting for instance to be running...'
  aws ec2 wait instance-running --instance-ids $InstanceId
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $NewIp = aws ec2 describe-instances `
    --instance-ids $InstanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' `
    --output text
  Write-Host "==> Public IP: $NewIp"

  $TmpJson = [System.IO.Path]::GetTempFileName()
  foreach ($Sub in @($OtelSub, $GrafanaSub)) {
    $Fqdn = "$Sub.$Domain"
    Write-Host "==> Updating Route53: $Fqdn -> $NewIp"

    @{
      Changes = @(@{
        Action = 'UPSERT'
        ResourceRecordSet = @{
          Name            = $Fqdn
          Type            = 'A'
          TTL             = 60
          ResourceRecords = @(@{ Value = $NewIp })
        }
      })
    } | ConvertTo-Json -Depth 10 | ForEach-Object { [System.IO.File]::WriteAllText($TmpJson, $_) }

    aws route53 change-resource-record-sets `
      --hosted-zone-id $HostedZoneId `
      --change-batch "file://$TmpJson" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Remove-Item $TmpJson -ErrorAction SilentlyContinue
      Write-Error "Route53 update failed: $Fqdn"
      exit 1
    }
  }
  Remove-Item $TmpJson -ErrorAction SilentlyContinue

  Write-Host ''
  Write-Host '==> Done. DNS propagation may take up to 60 seconds.'
  Write-Host "    Grafana : https://$GrafanaSub.$Domain"
  Write-Host "    OTel EP : https://$OtelSub.$Domain"
}
elseif ($Action -eq 'stop') {
  $InstanceId = Get-TfOutput 'instance_id'

  Write-Host "==> Stopping EC2: $InstanceId"
  aws ec2 stop-instances --instance-ids $InstanceId | Out-Null
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host '==> Stopped.'
}
elseif ($Action -eq 'setup') {
  $InstanceId    = Get-TfOutput 'instance_id'
  $Domain        = Get-TfOutput 'domain'
  $OtelEp        = Get-TfOutput 'otel_endpoint'
  $GrafanaUrl    = Get-TfOutput 'grafana_url'
  $SshPort       = Get-TfOutput 'ssh_port'
  $OtelDomain    = $OtelEp -replace 'https://', ''
  $GrafanaDomain = $GrafanaUrl -replace 'https://', ''

  if ([string]::IsNullOrEmpty($KeyFile)) {
    Write-Error "Specify -KeyFile. Example: .\manage.ps1 setup -KeyFile ~/.ssh/my-key.pem"
    exit 1
  }

  $Ip    = Get-InstanceIp $InstanceId
  $Email = "admin@$Domain"

  Write-Host "==> EC2: $Ip (SSH port: $SshPort)"
  Write-Host "==> OTel domain   : $OtelDomain"
  Write-Host "==> Grafana domain: $GrafanaDomain"
  Write-Host ''

  Write-Host '==> Uploading setup.sh...'
  scp -i $KeyFile -o StrictHostKeyChecking=no -P $SshPort setup.sh "ec2-user@${Ip}:/tmp/setup.sh"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Write-Host '==> Running setup (this may take a few minutes)...'
  ssh -i $KeyFile -o StrictHostKeyChecking=no -p $SshPort "ec2-user@$Ip" `
    "sudo bash /tmp/setup.sh $OtelDomain $GrafanaDomain $Email"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Write-Host ''
  Write-Host '==> Setup complete. Run deploy next:'
  Write-Host "    .\manage.ps1 deploy -KeyFile $KeyFile"
}
elseif ($Action -eq 'deploy') {
  $InstanceId    = Get-TfOutput 'instance_id'
  $OtelEp        = Get-TfOutput 'otel_endpoint'
  $GrafanaUrl    = Get-TfOutput 'grafana_url'
  $SshPort       = Get-TfOutput 'ssh_port'
  $OtelDomain    = $OtelEp -replace 'https://', ''
  $GrafanaDomain = $GrafanaUrl -replace 'https://', ''

  if ([string]::IsNullOrEmpty($KeyFile)) {
    Write-Error "Specify -KeyFile. Example: .\manage.ps1 deploy -KeyFile ~/.ssh/my-key.pem"
    exit 1
  }

  if (-not (Test-Path '.env')) {
    Write-Error ".env not found. Copy .env.example to .env and fill in the values."
    exit 1
  }
  if (-not (Test-Path 'otel.htpasswd')) {
    Write-Error "otel.htpasswd not found. Create with htpasswd output redirected to otel.htpasswd (see .env.example)."
    exit 1
  }

  $Ip = Get-InstanceIp $InstanceId

  Write-Host "==> EC2: $Ip (SSH port: $SshPort)"
  Write-Host "==> OTel domain   : $OtelDomain"
  Write-Host "==> Grafana domain: $GrafanaDomain"
  Write-Host ''

  Write-Host '==> Uploading config files...'
  $Target = "ec2-user@${Ip}:/opt/claude-monitoring/"
  $SshOpt = @('-i', $KeyFile, '-o', 'StrictHostKeyChecking=no', '-P', $SshPort)
  scp @SshOpt 'docker-compose.yml' $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt '.env'               $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt 'otelcol-config.yaml' $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt 'otel.htpasswd'      $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt -r 'prometheus'      $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  # grafana は古いファイルが残らないようディレクトリごと削除してから転送
  ssh -i $KeyFile -o StrictHostKeyChecking=no -p $SshPort "ec2-user@$Ip" `
    'rm -rf /opt/claude-monitoring/grafana/'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt -r 'grafana'         $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt -r 'nginx'           $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  scp @SshOpt -r 'loki'            $Target; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  # nginx 設定：ドメイン名を置換して /etc/nginx/conf.d/ に配置
  Write-Host '==> Configuring nginx...'
  ssh -i $KeyFile -o StrictHostKeyChecking=no -p $SshPort "ec2-user@$Ip" `
    "sed 's/`${OTEL_DOMAIN}/$OtelDomain/g; s/`${GRAFANA_DOMAIN}/$GrafanaDomain/g' /opt/claude-monitoring/nginx/nginx.conf | sudo tee /etc/nginx/conf.d/claude-monitoring.conf > /dev/null && sudo nginx -t && sudo systemctl reload nginx"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  # docker compose 起動 + 設定変更を反映するため再起動
  Write-Host '==> Starting and restarting containers...'
  ssh -i $KeyFile -o StrictHostKeyChecking=no -p $SshPort "ec2-user@$Ip" `
    'cd /opt/claude-monitoring && docker compose up -d && docker compose restart'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Write-Host ''
  Write-Host '==> Deploy complete.'
  Write-Host "    Grafana : https://$GrafanaDomain"
  Write-Host "    OTel EP : https://$OtelDomain"
}
