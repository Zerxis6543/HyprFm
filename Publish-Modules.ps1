$Server     = "http://127.0.0.1:3000"
$ModulesDir = "G:\FivemSTDBProject\HyprFm\stdb-modules"
$SidecarDir = "G:\FivemSTDBProject\HyprFm\stdb-sidecar"
$GeneratedDir = "$SidecarDir\Generated"

$Modules = @(
    @{ Path = "fivem-game/spacetimedb"; Db = "fivem-game"; Wasm = "stdb_fivem_game.wasm" }
)

Write-Host "[Publish] Building all modules..." -ForegroundColor Cyan
cd $ModulesDir
cargo build --target wasm32-unknown-unknown --release
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Build failed." -ForegroundColor Red; exit 1 }

foreach ($m in $Modules) {
    Write-Host "[Publish] Publishing $($m.Db)..." -ForegroundColor Cyan
    echo y | spacetime publish -p $m.Path --server $Server $m.Db --delete-data
    if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Failed to publish $($m.Db)." -ForegroundColor Red; exit 1 }
}

Write-Host "[Publish] Generating C# bindings..." -ForegroundColor Cyan
$mainWasm = "$ModulesDir\target\wasm32-unknown-unknown\release\stdb_fivem_game.wasm"
Write-Host "  -> stdb_fivem_game.wasm" -ForegroundColor Gray
spacetime generate -l csharp -b $mainWasm -o $GeneratedDir
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Generate failed." -ForegroundColor Red; exit 1 }

Write-Host "[Publish] Rebuilding sidecar..." -ForegroundColor Cyan
cd $SidecarDir
dotnet build
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Sidecar build failed." -ForegroundColor Red; exit 1 }

Write-Host "[Publish] Building NUI..." -ForegroundColor Cyan
Set-Location -LiteralPath "G:\FivemSTDBProject\HyprFm\fivem-server-files\resources\[core]\stdb-inventory\web"
npm run build
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] NUI build failed." -ForegroundColor Red; exit 1 }

Write-Host "[Publish] All done. Restart stdb-inventory in the FiveM console." -ForegroundColor Green