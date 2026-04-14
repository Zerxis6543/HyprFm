# Load .env if present
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
        }
    }
}

$ProjectRoot  = $PSScriptRoot
$SidecarPath  = Join-Path $ProjectRoot "stdb-sidecar"
$SidecarDll   = Join-Path $SidecarPath "bin\StdbSidecar.dll"
$FxServerExe  = Join-Path $ProjectRoot "fxserver\FXServer.exe"
$ServerData   = Join-Path $ProjectRoot "fivem-server-files"

$StdbUri = if ($env:STDB_URI) { $env:STDB_URI } else { "ws://127.0.0.1:3000" }
$StdbDb  = if ($env:STDB_DB)  { $env:STDB_DB }  else { "fivem-game" }
$FxPort  = if ($env:FX_PORT)  { $env:FX_PORT }  else { "30120" }

function Wait-ForPort($Port) {
    Write-Host "[Check] Waiting for port $Port..." -ForegroundColor Gray
    while ($true) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $Port)
            $tcp.Close()
            break
        } catch { Start-Sleep -Milliseconds 500 }
    }
}

# Force build if DLL missing
if ($args -contains "-build" -or -not (Test-Path $SidecarDll)) {
    Write-Host "[Build] Building sidecar..." -ForegroundColor Yellow
    Push-Location $SidecarPath
    dotnet build -c Release -o "$SidecarPath\bin"
    Pop-Location
}

try {
    Write-Host "[Launch] Starting SpacetimeDB..." -ForegroundColor Cyan
    $stdb = Start-Process "spacetime" -ArgumentList "start" -PassThru -WindowStyle Normal
    Wait-ForPort 3000
    Start-Sleep -Seconds 1

    Write-Host "[Launch] Starting sidecar..." -ForegroundColor Cyan
    $env:STDB_URI = $StdbUri
    $env:STDB_DB  = $StdbDb
    $env:FX_PORT  = $FxPort
    $sidecar = Start-Process "dotnet" -ArgumentList $SidecarDll -PassThru -WindowStyle Normal
    Wait-ForPort 27200   # wait for sidecar health endpoint

    Write-Host "[Launch] Starting FXServer..." -ForegroundColor Cyan
    $fx = Start-Process $FxServerExe -ArgumentList "+set citmp_serverDataPath $ServerData" -PassThru -WindowStyle Normal

    Write-Host "[Ready] HyprFM is online." -ForegroundColor Green
    Wait-Process -Id $fx.Id
}
finally {
    Write-Host "[Exit] Graceful shutdown..." -ForegroundColor Red
    # Signal FXServer to stop cleanly first
    Stop-Process -Id $fx.Id -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5   # allow in-flight reducers to complete
    Stop-Process -Id $sidecar.Id -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Stop-Process -Id $stdb.Id -ErrorAction SilentlyContinue
}