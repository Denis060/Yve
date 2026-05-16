# apply.ps1 — one-shot deploy script for Yve.
#
# Runs all pending DB migrations, deploys every Edge Function (with the
# right --no-verify-jwt flag for the Stripe webhook), and checks that the
# required Edge Function secrets are configured.
#
# Run from this directory (or any directory — the script anchors to its
# own location via $PSScriptRoot):
#
#   .\apply.ps1                # full deploy
#   .\apply.ps1 -SkipFunctions # migrations + secrets check only
#   .\apply.ps1 -SkipMigrations # functions + secrets check only
#
# Safe to re-run. supabase db push only applies migrations that aren't
# already recorded in supabase_migrations.schema_migrations; supabase
# functions deploy is idempotent.

[CmdletBinding()]
param(
  [switch]$SkipMigrations,
  [switch]$SkipFunctions,
  [switch]$SkipSecretsCheck
)

# Anchor to the script's directory so the script works no matter where the
# caller's CWD is. supabase CLI needs to see supabase/config.toml here.
Set-Location -Path $PSScriptRoot

function Write-Step($message) {
  Write-Host ''
  Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Ok($message) {
  Write-Host "  [ok] $message" -ForegroundColor Green
}

function Write-Warn($message) {
  Write-Host "  [warn] $message" -ForegroundColor Yellow
}

function Write-Bad($message) {
  Write-Host "  [fail] $message" -ForegroundColor Red
}

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------
Write-Step 'Preflight checks'

$supabaseCmd = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabaseCmd) {
  Write-Bad 'Supabase CLI not found on PATH.'
  Write-Host '       Install: https://supabase.com/docs/guides/cli'
  exit 1
}
Write-Ok "Supabase CLI: $($supabaseCmd.Source)"

if (-not (Test-Path 'supabase/config.toml')) {
  Write-Bad 'supabase/config.toml not found. Run this script from the repo root.'
  exit 1
}
Write-Ok 'supabase/config.toml found'

# ----------------------------------------------------------------------
# Migrations
# ----------------------------------------------------------------------
if ($SkipMigrations) {
  Write-Step 'Skipping migrations (per -SkipMigrations flag)'
} else {
  Write-Step 'Applying migrations (supabase db push)'
  Write-Host '       You will be prompted to confirm before any SQL runs.'
  Write-Host ''

  supabase db push
  if ($LASTEXITCODE -ne 0) {
    Write-Bad "supabase db push exited with code $LASTEXITCODE"
    Write-Host '       Common causes:'
    Write-Host '         - project not linked: supabase link --project-ref <ref>'
    Write-Host '         - not logged in: supabase login'
    Write-Host '         - migration SQL conflict: read the error above'
    exit 1
  }
  Write-Ok 'Migrations applied'
}

# ----------------------------------------------------------------------
# Edge Functions
# ----------------------------------------------------------------------
if ($SkipFunctions) {
  Write-Step 'Skipping function deploy (per -SkipFunctions flag)'
} else {
  Write-Step 'Deploying Edge Functions'

  $functions = @(
    @{ name = 'yve-chat';                 noVerify = $false },
    @{ name = 'ingest-material';          noVerify = $false },
    @{ name = 'vision-ingest';            noVerify = $false },
    @{ name = 'yve-recap';                noVerify = $false },
    @{ name = 'infer-profile';            noVerify = $false },
    @{ name = 'create-checkout-session';  noVerify = $false },
    @{ name = 'stripe-webhook';           noVerify = $true  }
  )

  foreach ($fn in $functions) {
    $name = $fn.name
    Write-Host "  deploying $name..."
    if ($fn.noVerify) {
      supabase functions deploy $name --no-verify-jwt
    } else {
      supabase functions deploy $name
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Bad "Failed to deploy $name (exit $LASTEXITCODE)"
      Write-Host '       Other functions deployed above are unaffected. Re-run after fixing.'
      exit 1
    }
    Write-Ok "$name deployed"
  }
}

# ----------------------------------------------------------------------
# Secrets check
# ----------------------------------------------------------------------
if ($SkipSecretsCheck) {
  Write-Step 'Skipping secrets check (per -SkipSecretsCheck flag)'
} else {
  Write-Step 'Checking Edge Function secrets'

  $secretsRaw = supabase secrets list
  if ($LASTEXITCODE -ne 0) {
    Write-Warn 'Could not list secrets — check them manually in the dashboard:'
    Write-Host '       Supabase dashboard -> Project Settings -> Edge Functions -> Secrets'
  } else {
    $secretsBlob = ($secretsRaw -join "`n")

    $requiredCore = @('ANTHROPIC_API_KEY', 'VOYAGE_API_KEY')
    $stripeSecrets = @('STRIPE_SECRET_KEY', 'STRIPE_PRICE_ID', 'STRIPE_WEBHOOK_SECRET')

    function Test-SecretSet($name) {
      return $secretsBlob -match ('\b' + [Regex]::Escape($name) + '\b')
    }

    # Core: required for the app to work at all
    $missingCore = @()
    foreach ($n in $requiredCore) {
      if (Test-SecretSet $n) {
        Write-Ok "$n is set"
      } else {
        Write-Bad "$n is missing"
        $missingCore += $n
      }
    }
    if ($missingCore.Count -gt 0) {
      Write-Host ''
      Write-Host '       Set with:'
      foreach ($n in $missingCore) {
        Write-Host "         supabase secrets set $n=<value>"
      }
    }

    # Stripe: optional, but if any is set then all should be set
    $stripeSet = @()
    $stripeMissing = @()
    foreach ($n in $stripeSecrets) {
      if (Test-SecretSet $n) { $stripeSet += $n } else { $stripeMissing += $n }
    }

    if ($stripeSet.Count -eq 0) {
      Write-Warn 'Stripe secrets not set — subscription / upgrade flow will not work.'
      Write-Host '       Skip this if you are not shipping monetization yet. Otherwise set:'
      foreach ($n in $stripeSecrets) {
        Write-Host "         supabase secrets set $n=<value>"
      }
    } elseif ($stripeMissing.Count -gt 0) {
      Write-Warn 'Stripe is partially configured. Missing:'
      foreach ($n in $stripeMissing) {
        Write-Host "         supabase secrets set $n=<value>"
      }
    } else {
      foreach ($n in $stripeSecrets) { Write-Ok "$n is set" }
    }

    # Optional Anthropic model overrides — informational only
    $optionalAnthropic = @(
      'ANTHROPIC_MODEL',
      'ANTHROPIC_VISION_MODEL',
      'ANTHROPIC_METADATA_MODEL',
      'ANTHROPIC_INFER_MODEL'
    )
    foreach ($n in $optionalAnthropic) {
      if (Test-SecretSet $n) {
        Write-Ok "$n is set (override)"
      }
    }
  }
}

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  cd mobile; flutter pub get; flutter run'
Write-Host ''
Write-Host 'If you have not yet run flutter create . to scaffold ios/android folders,'
Write-Host 'do that first, then add the permission entries from README.md.'
Write-Host ''
