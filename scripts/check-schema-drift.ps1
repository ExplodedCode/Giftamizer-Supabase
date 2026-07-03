<#
Compares the schema produced by a fresh local install (built from
volumes/db/*.sql and volumes/db/giftamizer/*.sql) against a live database's
actual schema (public + storage), so drift gets caught automatically instead
of being discovered months later. Equivalent to check-schema-drift.sh, for
Windows users not using Git Bash.

Usage:
  .\scripts\check-schema-drift.ps1 "postgres://user:pass@host:port/dbname"
  $env:PROD_DB_URL = "postgres://..."; .\scripts\check-schema-drift.ps1

The connection string is never written to disk by this script - pass it
directly or via an env var each time you run it.
#>

param(
    [Parameter(Position = 0)] [string]$RemoteDbUrl
)

Set-Location (Join-Path $PSScriptRoot '..')

if (-not $RemoteDbUrl) { $RemoteDbUrl = $env:PROD_DB_URL }
if (-not $RemoteDbUrl) {
    Write-Host "Usage: .\scripts\check-schema-drift.ps1 <postgres-connection-string>"
    Write-Host '   or: $env:PROD_DB_URL = "postgres://..."; .\scripts\check-schema-drift.ps1'
    exit 1
}

$project = 'schema-drift-check'
$composeFiles = @('-f', 'docker-compose.yml', '-f', './dev/docker-compose.dev.yml', '-f', './scripts/docker-compose.drift-check.yml')
$pgImage = (Select-String -Path 'docker-compose.yml' -Pattern 'supabase/postgres:\S+').Matches[0].Value

$localSchema = New-TemporaryFile
$remoteSchema = New-TemporaryFile

function Invoke-Cleanup {
    docker rm -f db-drift-check *> $null
    docker compose -p $project --env-file .env.example @composeFiles down -v *> $null
    Remove-Item -Force $localSchema, $remoteSchema -ErrorAction SilentlyContinue
}

function Select-SchemaLines {
    param([Parameter(ValueFromPipeline = $true)][string]$Line)
    process {
        if ($Line -notmatch '^(--|SET |SELECT pg_catalog\.set_config|\\restrict|\\unrestrict)' -and $Line.Trim() -ne '') {
            $Line
        }
    }
}

try {
    # In case a previous run was interrupted before cleanup.
    docker rm -f db-drift-check *> $null

    Write-Host "==> Booting a throwaway database from volumes/db/*.sql (image: $pgImage)..."
    docker compose -p $project --env-file .env.example @composeFiles up -d db | Out-Null

    Write-Host "==> Waiting for it to become healthy..."
    $status = 'starting'
    for ($i = 0; $i -lt 60; $i++) {
        $status = docker inspect --format='{{.State.Health.Status}}' db-drift-check 2>$null
        if ($status -eq 'healthy') { break }
        Start-Sleep -Seconds 2
    }
    if ($status -ne 'healthy') {
        Write-Host "Local database never became healthy - aborting. Recent logs:"
        docker logs db-drift-check 2>&1 | Select-Object -Last 50
        exit 1
    }

    Write-Host "==> Dumping local (fresh-install) schema..."
    docker exec db-drift-check pg_dump -U postgres --schema-only --no-owner --no-privileges `
        --schema=public --schema=storage postgres | Select-SchemaLines | Set-Content -Path $localSchema

    Write-Host "==> Dumping remote schema..."
    docker run --rm $pgImage pg_dump --schema-only --no-owner --no-privileges `
        --schema=public --schema=storage $RemoteDbUrl | Select-SchemaLines | Set-Content -Path $remoteSchema

    Write-Host ""
    Write-Host "==> Diff (lines starting with '<' exist only in the remote DB, '>' only in the fresh local install):"
    Write-Host ""
    $diff = Compare-Object (Get-Content $remoteSchema) (Get-Content $localSchema)
    if (-not $diff) {
        Write-Host "No drift detected - public/storage schema matches."
    } else {
        foreach ($entry in $diff) {
            $marker = if ($entry.SideIndicator -eq '=>') { '>' } else { '<' }
            Write-Host "$marker $($entry.InputObject)"
        }
        Write-Host ""
        Write-Host "Drift found above. This is a text diff of two independent pg_dump runs, so"
        Write-Host "expect some harmless noise (object ordering, sequence values); focus on"
        Write-Host "added/removed CREATE TABLE/FUNCTION/POLICY/TRIGGER blocks. Patch"
        Write-Host "volumes/db/giftamizer/*.sql to match the remote DB, following the same"
        Write-Host "convention as past reconciliations (see README's 'Updating production' section)."
    }
}
finally {
    Invoke-Cleanup
}
