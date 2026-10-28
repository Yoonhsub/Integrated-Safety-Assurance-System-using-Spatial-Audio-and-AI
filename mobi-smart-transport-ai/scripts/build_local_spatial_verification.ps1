param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$repository=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$target=[IO.Path]::GetFullPath($OutputPath)
if($target.StartsWith($repository+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $target -eq $repository){throw 'Output must be outside the repository'}
if(Test-Path -LiteralPath $target){throw 'Preserve previous evidence: choose a new output directory'}
$font='C:/Windows/Fonts/malgun.ttf'
if(!(Test-Path -LiteralPath $font)){throw 'Local Korean font is required; no font download is performed'}
Push-Location (Join-Path $repository 'apps/passenger_app')
try {
  & flutter build web --debug --no-pub --no-web-resources-cdn --no-wasm-dry-run --pwa-strategy=none --dart-define=MOBI_LOCAL_SPATIAL_VERIFICATION=true --target=lib/local_spatial_verification_main.dart --output=$target
  if($LASTEXITCODE -ne 0){throw 'Flutter local Spatial Audio build failed'}
} finally {Pop-Location}
Copy-Item -LiteralPath $font -Destination (Join-Path $target 'assets/offline-test.ttf')
$bootstrap=Join-Path $target 'flutter_bootstrap.js'
(Get-Content -LiteralPath $bootstrap -Raw).Replace('_flutter.loader.load();','_flutter.loader.load({config:{fontFallbackBaseUrl:"http://127.0.0.1:5280/local-font-fallback/"}});') | Set-Content -LiteralPath $bootstrap -Encoding utf8
@"
<!doctype html><html lang="ko"><head><base href="/"><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; connect-src 'self'; font-src 'self' data:; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:;"><title>MOBI 로컬 Spatial Audio 검증</title></head><body><script>window.MOBI_SPATIAL_VERIFICATION=true;</script><script src="mobi_tts.js"></script><script src="mobi_spatial_cue.js"></script><script src="mobi_spatial_verification.js"></script><script src="flutter_bootstrap.js" async></script></body></html>
"@ | Set-Content -LiteralPath (Join-Path $target 'index.html') -Encoding utf8
Write-Output "Debug Spatial Audio verification build: $target; serve only on localhost:5280. No auto speech."
