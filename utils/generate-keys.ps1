<#
Generates a fresh JWT_SECRET and derives matching ANON_KEY / SERVICE_ROLE_KEY
JWTs, so a new environment doesn't have to share the demo keys baked into
.env.example. Equivalent to generate-keys.sh, for Windows users not using
Git Bash - uses .NET crypto instead of openssl, no external dependency.

Usage: .\utils\generate-keys.ps1
Prints KEY=value lines to stdout - review them, then paste into your .env.
This does not modify any files itself.
#>

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-Jwt([string]$Secret, [string]$Role, [long]$Iat, [long]$Exp) {
    $header = '{"alg":"HS256","typ":"JWT"}'
    $payload = '{"role":"' + $Role + '","iss":"supabase","iat":' + $Iat + ',"exp":' + $Exp + '}'

    $headerB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($payload))
    $signingInput = "$headerB64.$payloadB64"

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $signature = ConvertTo-Base64Url $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signingInput))
    } finally {
        $hmac.Dispose()
    }

    "$signingInput.$signature"
}

$jwtSecretBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($jwtSecretBytes)
$JWT_SECRET = -join ($jwtSecretBytes | ForEach-Object { $_.ToString('x2') })

$iat = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$exp = $iat + (10 * 365 * 24 * 60 * 60) # ~10 years

$ANON_KEY = New-Jwt -Secret $JWT_SECRET -Role 'anon' -Iat $iat -Exp $exp
$SERVICE_ROLE_KEY = New-Jwt -Secret $JWT_SECRET -Role 'service_role' -Iat $iat -Exp $exp

Write-Output "JWT_SECRET=$JWT_SECRET"
Write-Output "ANON_KEY=$ANON_KEY"
Write-Output "SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY"
