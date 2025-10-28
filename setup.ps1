# Windows one-shot setup: start Compose, wait for app, print URL
$ErrorActionPreference = "Stop"
$AppUrl = $env:APP_URL
if (-not $AppUrl) { $AppUrl = "http://localhost:5678" }
$Attempts = if (${env:ATTEMPTS}) { [int]${env:ATTEMPTS} } else { 30 }
$SleepBetween = if (${env:SLEEP_BETWEEN}) { [int]${env:SLEEP_BETWEEN} } else { 2 }
$ComposeFile = Join-Path $PSScriptRoot "docker-compose.yml"

Write-Host "== setup.ps1 =="
Write-Host "Target URL: $AppUrl"
Write-Host "Using compose file: $ComposeFile"

function Has-Cmd($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# 1) Check if Docker is installed
if (-not (Has-Cmd "docker")) {
    Write-Host "Docker not found. Would you like to install Docker Desktop? (y/n)" -ForegroundColor Yellow
    $choice = Read-Host
    if ($choice -eq 'y') {
        Write-Host "Downloading Docker Desktop for Windows..." -ForegroundColor Cyan
        $installerPath = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
        Invoke-WebRequest -Uri "https://desktop.docker.com/win/stable/Docker%20Desktop%20Installer.exe" -OutFile $installerPath
        Write-Host "Installing Docker Desktop. Please follow the installer prompts..." -ForegroundColor Cyan
        Start-Process $installerPath -Wait
        Write-Host "Please restart your computer after installation and run this script again." -ForegroundColor Yellow
        exit 0
    } else {
        throw "Docker not found. Please install Docker Desktop and re-run this script."
    }
}

# 2) Check if Docker is running
try {
    docker info | Out-Null
} catch {
    Write-Host "Docker is not running. Please start Docker Desktop and run this script again." -ForegroundColor Red
    exit 1
}

# 3) Start services in order (NEW LOGIC)
$ComposeCmd = "docker-compose"
if (Has-Cmd "docker compose") { $ComposeCmd = "docker compose" }

# Start cloudflared first to get the URL
Write-Host "Starting Cloudflare tunnel..." -ForegroundColor Green
try {
    & $ComposeCmd -f "$ComposeFile" up -d cloudflared
} catch {
    Write-Host "Failed to start cloudflared service." -ForegroundColor Red
    exit 1
}

# Wait and get the tunnel URL
Write-Host "Waiting for tunnel URL..." -ForegroundColor Cyan
$tunnelUrl = $null
for ($i = 1; $i -le 10; $i++) { # Try for 20s
    $tunnelLogs = & $ComposeCmd -f "$ComposeFile" logs cloudflared 2>$null
    if ($tunnelLogs) {
        $tunnelUrl = $tunnelLogs | Select-String -Pattern "https://.*\.trycloudflare\.com" | 
                     ForEach-Object { $_.Matches.Value } | Select-Object -Last 1
        if ($tunnelUrl) {
            Write-Host "Got public URL: $tunnelUrl" -ForegroundColor Green
            break
        }
    }
    Write-Host "Attempt $i/10 - Waiting for tunnel URL..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

if (-not $tunnelUrl) {
    Write-Host "Could not determine Cloudflare Tunnel URL. Check 'docker compose logs cloudflared'." -ForegroundColor Red
    exit 1
}

# Set the URL as an environment variable for this session
# This variable will be passed into docker-compose
$env:N8N_PUBLIC_URL = $tunnelUrl

# Now, start n8n and postgres. 
# n8n will start postgres because of "depends_on"
Write-Host "Starting n8n and postgres services..." -ForegroundColor Green
try {
    & $ComposeCmd -f "$ComposeFile" up -d n8n
} catch {
    Write-Host "Failed to start n8n service." -ForegroundColor Red
    exit 1
}

# 4) Wait for the service to be ready (MODIFIED)
Write-Host "Waiting for service at $AppUrl..." -ForegroundColor Cyan
for ($i = 1; $i -le $Attempts; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $AppUrl -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            Write-Host "Ready: $AppUrl (HTTP $($resp.StatusCode))" -ForegroundColor Green
            
            # Print the public URL we found earlier
            Write-Host "Public URL (Cloudflare Tunnel): $env:N8N_PUBLIC_URL" -ForegroundColor Green
            
            exit 0
        }
    } catch {
        # This handles cases where n8n returns a 401 (Unauthorized) which is a "ready" state
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -ge 400 -and $_.Exception.Response.StatusCode.value__ -lt 500) {
            Write-Host "Ready: $AppUrl (HTTP $($_.Exception.Response.StatusCode.value__))" -ForegroundColor Green
            
            # Print the public URL we found earlier
            Write-Host "Public URL (Cloudflare Tunnel): $env:N8N_PUBLIC_URL" -ForegroundColor Green

            exit 0
        }
        Write-Host "Attempt $i/$Attempts - Waiting for service to be ready..." -ForegroundColor Yellow
        Start-Sleep -Seconds $SleepBetween
    }
}

Write-Warning "Containers started, but $AppUrl didn't respond yet."
Write-Host "Check container status: docker ps" -ForegroundColor Yellow
Write-Host "Check logs: docker compose -f '$ComposeFile' logs" -ForegroundColor Yellow
exit 1