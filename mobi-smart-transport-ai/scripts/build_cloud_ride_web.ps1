param(
  [Parameter(Mandatory=$true)][ValidateSet('passenger','driver')][string]$App,
  [Parameter(Mandatory=$true)][string]$Output,
  [string]$Flutter='flutter',
  [string]$DefinesFile=''
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$destination=[IO.Path]::GetFullPath($Output)
# Keep build outputs and any execution-specific defines outside Git.
if ($destination.Equals($repoRoot,[StringComparison]::OrdinalIgnoreCase) -or
    $destination.StartsWith($repoRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Verification output must be outside the repository'
}
$arguments=@('build','web','--release','--no-pub','--no-web-resources-cdn',
  '--pwa-strategy=none','--target=lib/cloud_ride_verification_main.dart',"--output=$destination")
if ($DefinesFile) {$arguments += "--dart-define-from-file=$DefinesFile"}
Push-Location (Join-Path $repoRoot "apps/${App}_app")
try {
  & $Flutter @arguments
  if ($LASTEXITCODE -ne 0) {throw 'Verification Web build failed'}
} finally {Pop-Location}
$index=Join-Path $destination 'index.html'
$html=[IO.File]::ReadAllText($index)
# These existing helpers install global gesture/audio/location hooks. Do not
# load them in verification, even when the Dart entrypoint fails closed.
$html=[regex]::Replace($html,'(?m)^\s*<script src="mobi_[a-z_]+\.js"></script>\s*\r?\n','')
if ($html -match '<script[^>]+src="mobi_') {throw 'Unexpected helper script in verification HTML'}
[IO.File]::WriteAllText($index,$html,[Text.UTF8Encoding]::new($false))
Write-Output "Verification-only HTML prepared: $App"
