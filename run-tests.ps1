param(
    [string]$Features = "",
    [string]$Env = "dev",
    [string]$Tags = "",
    [ValidateSet("", "smoke", "regression")]
    [string]$Profile = "",
    [bool]$AgentHeal = $true,
    [switch]$WriteExcel,
    [switch]$RestoreBackup
)

if ($RestoreBackup) {
    $testdataDir = Join-Path $PSScriptRoot "src\test\resources\features\loans\testdata"
    $backupDir = Join-Path $testdataDir "backup"
    if (Test-Path $backupDir) {
        Copy-Item -Path "$backupDir\*.xlsx" -Destination $testdataDir -Force
        Write-Host "Restored original Excel files from backup: $backupDir" -ForegroundColor Green
    } else {
        Write-Host "Backup directory not found: $backupDir" -ForegroundColor Red
        exit 1
    }
    if ($Features -eq "" -and $Tags -eq "" -and $Profile -eq "") {
        exit 0
    }
}

$mvnArgs = @(
    "test",
    "-Dkarate.env=$Env",
    "-Dkarate.agent.heal=$($AgentHeal.ToString().ToLower())",
    "-Dkarate.agent.writeExcel=$($WriteExcel.IsPresent.ToString().ToLower())"
)

if ($Profile -ne "") {
    $mvnArgs += "-P$Profile"
}

if ($Features -ne "") {
    $mvnArgs += "-Dkarate.features=$Features"
}

if ($Tags -ne "") {
    $mvnArgs += "-Dkarate.tags=$Tags"
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Running Standalone Karate Automation Tests" -ForegroundColor Cyan
Write-Host " Environment : $Env" -ForegroundColor White
Write-Host " Agent Heal  : $AgentHeal (WriteExcel: $($WriteExcel.IsPresent))" -ForegroundColor White
if ($Features -ne "") { Write-Host " Features    : $Features" -ForegroundColor White }
if ($Tags -ne "") { Write-Host " Tags        : $Tags" -ForegroundColor White }
if ($Profile -ne "") { Write-Host " Profile     : $Profile" -ForegroundColor White }
Write-Host " Command     : mvn $($mvnArgs -join ' ')" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Cyan

& mvn @mvnArgs
exit $LASTEXITCODE
