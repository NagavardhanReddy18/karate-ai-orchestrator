param(
    [string]$ConfigFile = "config\agent-config.properties",
    [string]$Env = "",
    [string]$Features = "",
    [string]$Tags = "",
    [switch]$RestoreBackup,
    [switch]$DisableHeal
)

$ErrorActionPreference = "Stop"
$agentRoot = $PSScriptRoot
$cfgPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile } else { Join-Path $agentRoot $ConfigFile }

$cfg = @{}
if (Test-Path $cfgPath) {
    Get-Content $cfgPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            $k = $line.Substring(0, $idx).Trim()
            $v = $line.Substring($idx + 1).Trim()
            $cfg[$k] = $v
        }
    }
}

$jdkHome   = $cfg["jdk.home"]
$jvmOpts   = if ($cfg["jvm.options"]) { $cfg["jvm.options"] } else { "-Xms512m -Xmx2048m -Dfile.encoding=UTF-8" }
$mvnCmd    = if ($cfg["maven.cmd"]) { $cfg["maven.cmd"] } else { "mvn" }
$brainRaw  = if ($cfg["agent.brain.dir"]) { $cfg["agent.brain.dir"] } else { "./brain" }
$brainDir  = if ([System.IO.Path]::IsPathRooted($brainRaw)) { $brainRaw } else { [System.IO.Path]::GetFullPath((Join-Path $agentRoot $brainRaw)) }

$targetEnv = if ($Env -ne "") { $Env } elseif ($cfg["karate.env"]) { $cfg["karate.env"] } else { "9190" }
$targetFeatures = if ($Features -ne "") { $Features } elseif ($cfg["karate.features"]) { $cfg["karate.features"] } else { "" }
$baseUrl   = $cfg["lo.test.baseUrl"]
$healFlag  = if ($DisableHeal) { "false" } elseif ($cfg["karate.agent.heal"]) { $cfg["karate.agent.heal"] } else { "true" }
$writeFlag = if ($cfg["karate.agent.writeExcel"]) { $cfg["karate.agent.writeExcel"] } else { "true" }

if ($jdkHome -and (Test-Path $jdkHome)) {
    $env:JAVA_HOME = $jdkHome
    $env:PATH = (Join-Path $jdkHome "bin") + ";" + $env:PATH
}
$env:MAVEN_OPTS = $jvmOpts

New-Item -ItemType Directory -Force (Join-Path $brainDir "logs"), (Join-Path $brainDir "reports"), (Join-Path $brainDir "backups") | Out-Null

if ($RestoreBackup) {
    $backupDir = Join-Path $brainDir "backups"
    $testdataDir = Join-Path $agentRoot "src\test\resources\features\loans\testdata"
    Copy-Item -Path (Join-Path $backupDir "*.xlsx") -Destination $testdataDir -Force
    Write-Host "[Autonomous QA Agent] Restored original Excel baseline from: $backupDir" -ForegroundColor Green
    if ($Features -eq "" -and $Env -eq "" -and $Tags -eq "") { exit 0 }
}

$mvnArgs = @(
    "test",
    "-Dagent.config.file=$cfgPath",
    "-Dagent.brain.dir=$brainDir",
    "-Dkarate.env=$targetEnv",
    "-Dkarate.agent.heal=$healFlag",
    "-Dkarate.agent.writeExcel=$writeFlag"
)
if ($baseUrl -and $baseUrl.Trim() -ne "") { $mvnArgs += "-Dlo.test.baseUrl=$baseUrl" }
if ($targetFeatures -ne "") { $mvnArgs += "-Dkarate.features=$targetFeatures" }
if ($Tags -ne "") { $mvnArgs += "-Dkarate.tags=$Tags" }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $brainDir "logs\agent-run-$timestamp.log"

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " KARATE AUTONOMOUS QA AGENT" -ForegroundColor Cyan
Write-Host " Root       : $agentRoot" -ForegroundColor White
Write-Host " Config     : $cfgPath" -ForegroundColor White
Write-Host " JAVA_HOME  : $env:JAVA_HOME" -ForegroundColor White
Write-Host " MAVEN_OPTS : $env:MAVEN_OPTS" -ForegroundColor White
Write-Host " Brain Dir  : $brainDir" -ForegroundColor White
Write-Host " Target Env : $targetEnv" -ForegroundColor White
Write-Host " Self-Heal  : $healFlag (WriteExcel: $writeFlag)" -ForegroundColor White
Write-Host " Log File   : $logFile" -ForegroundColor Yellow
Write-Host "========================================================================" -ForegroundColor Cyan

Push-Location $agentRoot
try {
    & $mvnCmd @mvnArgs 2>&1 | Tee-Object -FilePath $logFile
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "[Autonomous QA Agent] Reports saved to: $(Join-Path $brainDir 'reports')" -ForegroundColor Green
exit $exitCode
