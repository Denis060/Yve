# Builds the Yve web app for production and copies in the static files
# Flutter's web build skips (.well-known/, legal/ HTML pages, vercel.json).
#
# Run from anywhere; uses absolute paths so it doesn't matter what your
# cwd is. Output lands at mobile/build/web/.
#
# After this runs, deploy with:
#   cd mobile/build/web
#   vercel --prod

$ErrorActionPreference = "Stop"

$REPO   = "C:\Apps\StudyBuddy"
$MOBILE = "$REPO\mobile"
$WEB    = "$MOBILE\web"
$OUT    = "$MOBILE\build\web"
$FLUTTER = "C:\Users\fofan\Downloads\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat"

if (-not (Test-Path $FLUTTER)) {
    throw "Flutter not found at $FLUTTER"
}

Write-Host "==> Flutter web build" -ForegroundColor Cyan
Set-Location $MOBILE
& $FLUTTER build web --release --dart-define-from-file=dart_defines.json --base-href=/
if ($LASTEXITCODE -ne 0) { throw "flutter build web failed" }

Write-Host "==> Copying static files Flutter's build skips" -ForegroundColor Cyan

# .well-known/ — Flutter's web build doesn't copy hidden directories.
$wellKnownSrc = Join-Path $WEB ".well-known"
$wellKnownDst = Join-Path $OUT ".well-known"
if (Test-Path $wellKnownSrc) {
    Copy-Item -Path $wellKnownSrc -Destination $wellKnownDst -Recurse -Force
    Write-Host "  + .well-known/"
}

# legal/ — pre-rendered HTML pages
$legalSrc = Join-Path $WEB "legal"
$legalDst = Join-Path $OUT "legal"
if (Test-Path $legalSrc) {
    Copy-Item -Path $legalSrc -Destination $legalDst -Recurse -Force
    Write-Host "  + legal/"
}

# auth/ — OAuth callback bridge page (JS-triggered intent → Yve app)
$authSrc = Join-Path $WEB "auth"
$authDst = Join-Path $OUT "auth"
if (Test-Path $authSrc) {
    Copy-Item -Path $authSrc -Destination $authDst -Recurse -Force
    Write-Host "  + auth/"
}

# checkout/ — Stripe return bridge pages
$checkoutSrc = Join-Path $WEB "checkout"
$checkoutDst = Join-Path $OUT "checkout"
if (Test-Path $checkoutSrc) {
    Copy-Item -Path $checkoutSrc -Destination $checkoutDst -Recurse -Force
    Write-Host "  + checkout/"
}

# upgrade/ — legacy alias for checkout/ in case Stripe still has old
# success/cancel URLs cached on existing customers' subscriptions.
$upgradeSrc = Join-Path $WEB "upgrade"
$upgradeDst = Join-Path $OUT "upgrade"
if (Test-Path $upgradeSrc) {
    Copy-Item -Path $upgradeSrc -Destination $upgradeDst -Recurse -Force
    Write-Host "  + upgrade/"
}

# vercel.json — routing + headers config
$vercelSrc = Join-Path $WEB "vercel.json"
if (Test-Path $vercelSrc) {
    Copy-Item -Path $vercelSrc -Destination $OUT -Force
    Write-Host "  + vercel.json"
}

Write-Host ""
Write-Host "==> Build complete" -ForegroundColor Green
Write-Host "    Output: $OUT"
Write-Host ""
Write-Host "Next:"
Write-Host "    cd $OUT"
Write-Host "    vercel --prod"
