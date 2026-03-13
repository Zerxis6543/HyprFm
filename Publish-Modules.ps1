$Server     = "http://127.0.0.1:3000"
$ModulesDir = "G:\FIVEMSTDBPROJECT\stdb-modules"
$SidecarDir = "G:\FIVEMSTDBPROJECT\stdb-sidecar"
$GeneratedDir = "$SidecarDir\Generated"

$Modules = @(
    @{ Path = "fivem-game/spacetimedb"; Db = "fivem-game";       Wasm = "stdb_fivem_game.wasm" },
    @{ Path = "core/spacetimedb";       Db = "core-jzzxp";       Wasm = "stdb_core.wasm"       },
    @{ Path = "inventory/spacetimedb";  Db = "inventory-55buo";  Wasm = "stdb_inventory.wasm"  },
    @{ Path = "player/spacetimedb";     Db = "player-qouxn";     Wasm = "stdb_player.wasm"     }
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
foreach ($m in $Modules) {
    $wasm = "$ModulesDir\target\wasm32-unknown-unknown\release\$($m.Wasm)"
    Write-Host "  -> $($m.Wasm)" -ForegroundColor Gray
    spacetime generate -l csharp -b $wasm -o $GeneratedDir
    if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Generate failed for $($m.Wasm)." -ForegroundColor Red; exit 1 }
}

Write-Host "[Publish] Rebuilding sidecar..." -ForegroundColor Cyan
cd $SidecarDir
dotnet build
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] Sidecar build failed." -ForegroundColor Red; exit 1 }

Write-Host "[Publish] Building NUI..." -ForegroundColor Cyan
cd "G:\FIVEMSTDBPROJECT\fivem-server-files\resources\[core]\stdb-inventory"
npm run build
if ($LASTEXITCODE -ne 0) { Write-Host "[Publish] NUI build failed." -ForegroundColor Red; exit 1 }

Write-Host "[Publish] All done. Restart stdb-inventory in the FiveM console." -ForegroundColor Green