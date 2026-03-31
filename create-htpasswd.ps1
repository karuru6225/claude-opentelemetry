#Requires -Version 5.1
# Generate otel.htpasswd interactively.
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
# htpasswd -niB: read password from stdin, hash with bcrypt, print to stdout
$plain1 | docker run --rm -i httpd htpasswd -niB claude | `
  Out-File -FilePath 'otel.htpasswd' -Encoding ascii -NoNewline

[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)

if ($LASTEXITCODE -ne 0) {
  Write-Error 'Failed to generate htpasswd. Make sure Docker is running.'
  exit 1
}

Write-Host '==> otel.htpasswd created.'
