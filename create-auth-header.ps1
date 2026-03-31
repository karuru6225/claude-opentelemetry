#Requires -Version 5.1
# Generate the Base64-encoded Basic Auth header value for OTEL_EXPORTER_OTLP_HEADERS.
# Password is read via prompt so it never appears in command history.

$securePassword = Read-Host -Prompt 'Enter OTel password' -AsSecureString

$bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("claude:$plain"))
$plain   = $null

Write-Host ''
Write-Host 'Add the following to ~/.claude/settings.json:'
Write-Host ''
Write-Host "  `"OTEL_EXPORTER_OTLP_HEADERS`": `"Authorization=Basic $encoded`""
