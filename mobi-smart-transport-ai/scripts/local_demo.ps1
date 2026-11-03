param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Build','Start','Stop','Status','Verify')][string]$Action,
    [Parameter(Mandatory)][string]$WorkDir,
    [string]$Flutter = 'C:\Flutter SDK\flutter\bin\flutter.bat',
    [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$python = Join-Path $projectRoot 'backend\api\.venv\Scripts\python.exe'
$tool = Join-Path $PSScriptRoot 'local_demo.py'
$work = [System.IO.Path]::GetFullPath($WorkDir)
$statePath = Join-Path $work 'processes.json'

function Invoke-Python([string[]]$Arguments) {
    & $python -B @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Python command failed ($LASTEXITCODE)" }
}
function Save-State { ConvertTo-Json -InputObject @($script:owned) -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8 }
function Start-Owned([string]$Name, [string]$File, [string]$Arguments) {
    $proc = Start-Process -FilePath $File -ArgumentList $Arguments -WorkingDirectory $work -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $work "$Name.stdout.log") -RedirectStandardError (Join-Path $work "$Name.stderr.log")
    $script:owned += @{ Name=$Name; Pid=$proc.Id; StartedTicks=$proc.StartTime.ToUniversalTime().Ticks.ToString() }
    Save-State
}
function Stop-Owned {
    if (!(Test-Path -LiteralPath $statePath)) { return }
    foreach ($entry in @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)) {
        $proc = Get-Process -Id $entry.Pid -ErrorAction SilentlyContinue
        if ($proc -and $proc.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$entry.StartedTicks) {
            throw "Process identity mismatch for $($entry.Name); state retained and process not stopped."
        }
        if ($proc) {
            # Only the exact processes launched here (including their children).
            & taskkill.exe /PID $entry.Pid /T /F | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to stop $($entry.Name); state retained." }
        }
    }
    Remove-Item -LiteralPath $statePath
}
function Wait-Http([string]$Url) {
    $deadline = (Get-Date).AddSeconds(120)
    do {
        try { $null = Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing; return } catch {}
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    throw "Readiness timeout: $Url (see logs in $work)"
}

switch ($Action) {
    'Prepare' { Invoke-Python @($tool, 'prepare', '--output', $work) }
    'Build' { Invoke-Python @($tool, 'build', '--output', $work, '--flutter', $Flutter) }
    'Stop' { Stop-Owned; Write-Output 'Owned local demo services stopped. Emulator data is disposable.' }
    'Status' {
        if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath }
        try { Invoke-RestMethod http://127.0.0.1:8001/health -TimeoutSec 3 } catch { Write-Output 'Backend not ready' }
    }
    'Verify' { Invoke-Python @((Join-Path $PSScriptRoot 'smoke_local_demo.py'), '--output', (Join-Path $work 'verification.json')) }
    'Start' {
        if (Test-Path -LiteralPath $statePath) { throw 'Existing process state: use Status/Stop first.' }
        $marker = Get-Content -LiteralPath (Join-Path $work 'local-demo.json') -Raw | ConvertFrom-Json
        if ($marker.project -ne 'demo-mobi-local' -or !$marker.local_only) { throw 'Not a prepared local demo workspace' }
        foreach ($port in @(8001,9000,9099,4400,4500,5173,5174)) {
            if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { throw "Port $port already in use; no process was stopped." }
        }
        foreach ($name in @('passenger','driver')) {
            if (!(Test-Path (Join-Path $work "flutter-workspace/apps/${name}_app/build/web/index.html"))) { throw 'Run Build first' }
        }
        $firebaseCli = Join-Path $env:APPDATA 'npm/node_modules/firebase-tools/lib/bin/firebase.js'
        $node = (Get-Command node -ErrorAction Stop).Source
        if (!(Test-Path -LiteralPath $firebaseCli) -or !(Test-Path "$JavaHome/bin/java.exe")) { throw 'Firebase CLI and Java 21 are required' }
        $oldPath = $env:PATH; $oldJava = $env:JAVA_HOME
        $env:JAVA_HOME = $JavaHome; $env:PATH = "$JavaHome\bin;$env:PATH"
        $script:owned = @()
        try {
            Start-Owned 'emulators' $node "`"$firebaseCli`" emulators:start --only auth,database --project demo-mobi-local --config firebase.json"
            Wait-Http 'http://127.0.0.1:9099/'
            Wait-Http 'http://127.0.0.1:4400/emulators'
            Invoke-Python @($tool, 'seed')
            Start-Owned 'backend' $python "-B `"$tool`" backend"
            Wait-Http 'http://127.0.0.1:8001/health'
            $port = 5173
            foreach ($name in @('passenger','driver')) {
                $directory = Join-Path $work "flutter-workspace/apps/${name}_app/build/web"
                Start-Owned $name $python "-B -m http.server $port --bind 127.0.0.1 --directory `"$directory`""
                Wait-Http "http://127.0.0.1:$port/"
                $port++
            }
            Write-Output "Passenger http://127.0.0.1:5173 | Driver http://127.0.0.1:5174 | Logs $work"
        } catch { Stop-Owned; throw } finally { $env:PATH=$oldPath; $env:JAVA_HOME=$oldJava }
    }
}
