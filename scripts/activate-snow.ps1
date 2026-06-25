# Activate project venv and point Snowflake CLI at .snowflake/ in this repo.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SnowflakeHome = Join-Path $ProjectRoot ".snowflake"
$ConfigFile = Join-Path $SnowflakeHome "config.toml"
$ConfigExample = Join-Path $SnowflakeHome "config.toml.example"

$env:SNOWFLAKE_HOME = $SnowflakeHome

if (-not (Test-Path $ConfigFile)) {
    if (-not (Test-Path $ConfigExample)) {
        Write-Error "Missing $ConfigExample"
        exit 1
    }
    Copy-Item $ConfigExample $ConfigFile
    Write-Host "Created .snowflake\config.toml — edit it with your Snowflake credentials."
}

$VenvActivate = Join-Path $ProjectRoot ".venv\Scripts\Activate.ps1"
if (-not (Test-Path $VenvActivate)) {
    Write-Error "Missing .venv. Run: py -3.13 -m venv .venv; .\.venv\Scripts\python.exe -m pip install snowflake-cli"
    exit 1
}

. $VenvActivate
Write-Host "SNOWFLAKE_HOME=$env:SNOWFLAKE_HOME"
Write-Host "Run: snow connection test"
