<#
Thin convenience wrapper around the docker compose invocations used in this
repo, so you don't need to remember the multi-file flags. Everything here
is optional - a plain `docker compose -f ... up -d` works exactly the same.
Equivalent to run.sh, for Windows users not using Git Bash.

Usage:
  .\run.ps1 dev  {up|down|restart|logs [service]|ps}   local dev stack (inbucket mail, fresh db)
  .\run.ps1 prod {up|down|restart|logs [service]|ps}   production stack (no dev overrides)
  .\run.ps1 reset                                       wipe everything and start over (see reset.ps1)
#>

param(
    [Parameter(Position = 0)] [string]$EnvName,
    [Parameter(Position = 1)] [string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Rest
)

Set-Location $PSScriptRoot

function Show-Usage {
    Write-Host "Usage: .\run.ps1 {dev|prod} {up|down|restart|logs [service]|ps}"
    Write-Host "   or: .\run.ps1 reset"
    exit 1
}

if (-not $EnvName) { Show-Usage }

if ($EnvName -eq 'reset') {
    & "$PSScriptRoot\reset.ps1"
    exit $LASTEXITCODE
}

switch ($EnvName) {
    'dev'   { $files = @('-f', 'docker-compose.yml', '-f', './dev/docker-compose.dev.yml') }
    'prod'  { $files = @('-f', 'docker-compose.yml') }
    default { Show-Usage }
}

if (-not $Action) { Show-Usage }

switch ($Action) {
    'up'      { docker compose @files up -d @Rest }
    'down'    { docker compose @files down @Rest }
    'restart' { docker compose @files restart @Rest }
    'logs'    { docker compose @files logs -f @Rest }
    'ps'      { docker compose @files ps @Rest }
    default   { Show-Usage }
}
