$StdbUri     = "ws://127.0.0.1:3000"
$StdbDb      = "fivem-game"
$FxPort      = "30120"
$SidecarPath = "G:\FIVEMSTDBPROJECT\STFM\stdb-sidecar"
$FxServerExe = "G:\FIVEMSTDBPROJECT\STFM\fxserver\FXServer.exe"
$ServerData  = "G:\FIVEMSTDBPROJECT\STFM\fivem-server-files"

Write-Host "[Launch] Starting SpacetimeDB..." -ForegroundColor Cyan
$stdb = Start-Process "spacetime" -ArgumentList "start" -PassThru -WindowStyle Normal
Start-Sleep -Seconds 3

Write-Host "[Launch] Building sidecar..." -ForegroundColor Cyan
Push-Location $SidecarPath
dotnet build -c Release -o "$SidecarPath\bin"
Pop-Location

Write-Host "[Launch] Starting sidecar..." -ForegroundColor Cyan
$env:STDB_URI = $StdbUri
$env:STDB_DB  = $StdbDb
$env:FX_PORT  = $FxPort
$sidecar = Start-Process "dotnet" `
    -ArgumentList "$SidecarPath\bin\StdbSidecar.dll" `
    -PassThru -WindowStyle Normal
Start-Sleep -Seconds 2

Write-Host "[Launch] Starting FXServer..." -ForegroundColor Cyan
$fx = Start-Process $FxServerExe -PassThru -WindowStyle Normal

Write-Host "[Launch] All processes started." -ForegroundColor Green
Write-Host "  SpacetimeDB PID : $($stdb.Id)"
Write-Host "  Sidecar PID     : $($sidecar.Id)"
Write-Host "  FXServer PID    : $($fx.Id)"