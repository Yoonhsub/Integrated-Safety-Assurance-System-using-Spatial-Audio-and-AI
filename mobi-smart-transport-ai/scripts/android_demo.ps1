param(
    [ValidateSet('Check','Backend','Device','Install','Launch','RestartApp','StopApp','Disconnect','Backup')]
    [string]$Action = 'Check',
    [string]$BackendPython = $env:MOBI_BACKEND_PYTHON,
    [string]$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
    [string]$Aapt,
    [string]$Serial,
    [string]$Apk,
    [string]$ExpectedApkSha256,
    [string]$StateDir = "$env:LOCALAPPDATA\MobiDemo",
    [string]$BackupDir,
    [string]$BackupPython = 'python'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$packageName = 'com.example.mobi_passenger_app'
if (!$BackendPython) { $BackendPython = Join-Path $projectRoot 'backend\api\.venv\Scripts\python.exe' }
if (!$Apk) { $Apk = Join-Path $projectRoot 'apps\passenger_app\build\app\outputs\flutter-apk\app-debug.apk' }
$statePath = Join-Path $StateDir 'android-reverse.json'

function Invoke-Adb([string[]]$Arguments) {
    if (!(Test-Path -LiteralPath $Adb -PathType Leaf)) { throw 'ADB not found. Pass -Adb with the SDK adb.exe path.' }
    $result = & $Adb @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB command failed. Check the phone and USB cable. $result" }
    return $result
}
function Get-Device {
    # One inventory, no retry loop; never starts an emulator.
    $lines = @(Invoke-Adb @('devices'))
    $ready = @($lines | ForEach-Object {
        if ([string]$_ -match '^([^\s]+)\s+device$') { $Matches[1] }
    })
    if ($Serial) {
        if ($ready -notcontains $Serial) { throw 'Requested phone is not connected/authorized. No retry performed.' }
        return $Serial
    }
    if ($ready.Count -ne 1) { throw 'Connect/authorize exactly one phone, or pass -Serial. No retry performed.' }
    return $ready[0]
}
function Get-Health {
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8000/health' -TimeoutSec 4
        return [pscustomobject]@{ status=$h.status; service=$h.service; environment=$h.environment;
            firebaseMode=$h.firebaseMode; dataMode=$h.dataMode; firebaseInitialized=$h.firebaseInitialized;
            firebaseCredentialsReady=$h.firebaseCredentialsReady; firebaseLastError=$h.firebaseLastError }
    } catch { return $null }
}
function Get-ApkInfo {
    if (!(Test-Path -LiteralPath $Apk -PathType Leaf)) { throw 'APK not found. Build first or pass -Apk with a preserved artifact.' }
    if (!$script:Aapt) {
        $sdk = Split-Path (Split-Path $Adb -Parent) -Parent
        $candidates = @(Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if (!$candidates.Count) { throw 'aapt.exe not found. Pass -Aapt.' }
        $script:Aapt = $candidates[0]
    }
    $badging = & $script:Aapt dump badging $Apk
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect APK manifest.' }
    $line = @($badging | Where-Object { $_ -match "^package: name='([^']+)'" }) | Select-Object -First 1
    if ($line -and $line -match "^package: name='([^']+)'") { $actualPackage = $Matches[1] }
    else { throw 'APK package missing.' }
    if ($actualPackage -ne $packageName) { throw 'Only the normal Passenger APK is accepted, not isolated test apps.' }
    $hash = (Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{ package=$packageName; path=[IO.Path]::GetFullPath($Apk); sha256=$hash }
}

switch ($Action) {
    'Check' {
        Write-Output "Project: $projectRoot"
        Write-Output "Backend Python exists: $(Test-Path -LiteralPath $BackendPython -PathType Leaf)"
        Write-Output "ADB exists: $(Test-Path -LiteralPath $Adb -PathType Leaf)"
        Write-Output 'No device query, Firebase Admin test, login or settings change is performed.'
        $info = Get-ApkInfo
        Write-Output "APK package: $($info.package)"
        Write-Output "APK SHA256: $($info.sha256)"
        Write-Output "APK path: $($info.path)"
        $health = Get-Health
        if ($health) { $health | ConvertTo-Json -Compress } else { Write-Output 'Backend not responding. Run Backend in a separate terminal.' }
    }
    'Backend' {
        if (!(Test-Path -LiteralPath $BackendPython -PathType Leaf)) { throw 'Pass -BackendPython with the existing API virtual environment python.exe.' }
        $occupied = Get-Health
        if ($occupied) { throw 'Port 8000 already responds. Existing server was not stopped; inspect Check first.' }
        foreach ($name in @('FIREBASE_AUTH_EMULATOR_HOST','FIREBASE_DATABASE_EMULATOR_HOST','MOBI_LOCAL_DEMO')) {
            if ([Environment]::GetEnvironmentVariable($name, 'Process')) { throw "Unexpected emulator/demo variable $name. Use a clean terminal; nothing was changed." }
        }
        $config = @{
            FIREBASE_PROJECT_ID='mobi-smart-transport';
            FIREBASE_DATABASE_URL='https://mobi-smart-transport-default-rtdb.asia-southeast1.firebasedatabase.app';
            FIREBASE_USE_ADC='true'; FIREBASE_USE_MOCK='false'; APP_ENV='staging';
            MOBI_PASSENGER_CAMERA_PREVIEW='1'; FCM_ENABLED='false'; FCM_USE_MOCK='true';
            PYTHONDONTWRITEBYTECODE='1'
        }
        $saved = @{}
        foreach ($name in $config.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            foreach ($name in $config.Keys) { [Environment]::SetEnvironmentVariable($name, $config[$name], 'Process') }
            Push-Location (Join-Path $projectRoot 'backend\api')
            try {
                Write-Output 'Existing app.main:app | loopback 8000 | one worker | real Firebase Auth | FCM disabled.'
                Write-Output 'Existing ADC is used without modifying it. Ctrl+C ends this foreground server.'
                & $BackendPython -B -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1 --no-access-log
                if ($LASTEXITCODE -ne 0) { throw 'Backend exited with an error. No other process was stopped.' }
            } finally { Pop-Location }
        } finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }
    'Device' {
        $device = Get-Device
        $existing = @(Invoke-Adb @('-s',$device,'reverse','--list'))
        $mapping = @($existing | Where-Object { [string]$_ -match '\btcp:8000\s+' })
        if ($mapping.Count -and !([string]$mapping[0] -match '\btcp:8000\s+tcp:8000\s*$')) {
            throw 'A different reverse mapping owns tcp:8000. It was not replaced.'
        }
        $owned = !$mapping.Count
        if (Test-Path -LiteralPath $statePath) {
            $prior = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($prior.serial -ne $device) { throw 'Existing reverse ownership state belongs to another device. Resolve it first.' }
            if ($prior.createdHere) { $owned = $true }
        }
        Invoke-Adb @('-s',$device,'reverse','tcp:8000','tcp:8000') | Out-Null
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        @{serial=$device;createdHere=$owned;local='tcp:8000';remote='tcp:8000'} |
            ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
        Write-Output 'USB reverse ready. Keep the data cable connected during the demonstration.'
    }
    'Install' {
        $info = Get-ApkInfo
        if (!$ExpectedApkSha256 -or $info.sha256 -ne $ExpectedApkSha256.ToLowerInvariant()) {
            throw 'Pass -ExpectedApkSha256 matching the preserved artifact. No installation performed.'
        }
        $device = Get-Device
        Invoke-Adb @('-s',$device,'install','-r',$info.path)
        Write-Output 'Installed using -r. App data was not cleared; permission/login checks remain manual.'
    }
    'Launch' {
        $device = Get-Device
        Invoke-Adb @('-s',$device,'shell','am','start','-W','-n',"$packageName/.MainActivity")
    }
    'RestartApp' {
        $device = Get-Device
        Invoke-Adb @('-s',$device,'shell','am','force-stop',$packageName) | Out-Null
        Invoke-Adb @('-s',$device,'shell','am','start','-W','-n',"$packageName/.MainActivity")
    }
    'StopApp' {
        $device = Get-Device
        Invoke-Adb @('-s',$device,'shell','am','force-stop',$packageName) | Out-Null
    }
    'Disconnect' {
        if (!(Test-Path -LiteralPath $statePath)) { Write-Output 'No owned reverse state. Nothing removed.'; break }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if (!$state.createdHere) {
            Remove-Item -LiteralPath $statePath
            Write-Output 'Pre-existing reverse mapping retained; only script metadata removed.'
            break
        }
        $device = Get-Device
        if ($device -ne $state.serial) { throw 'Device does not match reverse ownership state.' }
        $mapping = @(Invoke-Adb @('-s',$device,'reverse','--list') | Where-Object { [string]$_ -match '\btcp:8000\s+tcp:8000\s*$' })
        if ($mapping.Count) { Invoke-Adb @('-s',$device,'reverse','--remove','tcp:8000') | Out-Null }
        Remove-Item -LiteralPath $statePath
        Write-Output 'Only this script-created tcp:8000 reverse was removed.'
    }
    'Backup' {
        if (!$BackupDir) { throw 'Pass -BackupDir with a NEW directory outside the Git worktree.' }
        & $BackupPython -B (Join-Path $PSScriptRoot 'backup_demo_workspace.py') --output $BackupDir --artifact $Apk
        if ($LASTEXITCODE -ne 0) { throw 'Backup incomplete. See the backup manifest/console; no source was removed.' }
    }
}
