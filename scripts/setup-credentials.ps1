#Requires -Version 5.1
# Generate otel.htpasswd and print the OTEL_EXPORTER_OTLP_HEADERS value.
# Password is read via prompt so it never appears in command history.

$securePassword = Read-Host -Prompt 'Enter OTel password' -AsSecureString
$confirm        = Read-Host -Prompt 'Confirm password' -AsSecureString

$bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm)
$plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
$plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)

if ($plain1 -ne $plain2) {
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
  Write-Error 'Passwords do not match.'
  exit 1
}
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)

# Generate bcrypt hash via docker and write to otel.htpasswd
$plain1 | docker run --rm -i httpd htpasswd -niB claude | `
  Out-File -FilePath 'otel.htpasswd' -Encoding ascii -NoNewline

if ($LASTEXITCODE -ne 0) {
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
  Write-Error 'Failed to generate htpasswd. Make sure Docker is running.'
  exit 1
}

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("claude:$plain1"))
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)

Write-Host ''
Write-Host '==> otel.htpasswd created.'
Write-Host ''
Write-Host 'Add the following to ~/.claude/settings.json:'
Write-Host ''
Write-Host "  `"OTEL_EXPORTER_OTLP_HEADERS`": `"Authorization=Basic $encoded`""
