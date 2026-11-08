#!/bin/bash
set -euo pipefail

# The old azd path registers providers, grants RBAC and immediately bootstraps the
# archived network/profile. It is not the 2026-10-27 shared SMAL deployment path.
# Fail BEFORE any provider, environment, credential or Azure resource operation.
echo 'ERROR: legacy azd provisioning is disabled for the shared SMAL landing zone.' >&2
echo 'Use the reviewed plan in docs/deployment-2026-10-27/README.md. No bootstrap is approved yet.' >&2
exit 1

# =============================================================================
# preprovision — governed vended-spoke LocalBox
#
# Assumes:
#   * You are logged in to az and the target subscription is selected.
#   * The signed-in user is Owner on the target subscription.
#   * The LZ spoke (vnet-az-test-wkl-san-1/snet-default) already exists.
# =============================================================================

echo "==> Registering required resource providers (idempotent)..."
for rp in \
  Microsoft.HybridCompute \
  Microsoft.GuestConfiguration \
  Microsoft.Kubernetes \
  Microsoft.KubernetesConfiguration \
  Microsoft.ExtendedLocation \
  Microsoft.AzureArcData \
  Microsoft.OperationsManagement \
  Microsoft.AzureStackHCI \
  Microsoft.ResourceConnector \
  Microsoft.OperationalInsights \
  Microsoft.HybridConnectivity \
  Microsoft.HybridContainerService \
  Microsoft.Attestation \
  Microsoft.EdgeMarketPlace \
  Microsoft.Compute ; do
  az provider register --namespace "$rp" >/dev/null 2>&1 || true
done
echo "    Providers registration requested."

# ---- Client VM SKU availability in the client VM region (not a hub region) ----
JS_LOCATION="${JS_LOCATION:-southafricanorth}"
JS_VM_SIZE="${JS_VM_SIZE:-Standard_E32s_v6}"
echo "==> Checking client VM SKU $JS_VM_SIZE availability in $JS_LOCATION..."
restriction=$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq '${JS_LOCATION}'" \
  --query "value[?name=='${JS_VM_SIZE}'].restrictions[0].reasonCode | [0]" -o tsv 2>/dev/null || echo "")
if [ "$restriction" = "NotAvailableForSubscription" ]; then
  echo "ERROR: $JS_VM_SIZE is restricted (NotAvailableForSubscription) in $JS_LOCATION. Aborting." >&2
  exit 1
fi
echo "    $JS_VM_SIZE is available in $JS_LOCATION."

# =============================================================================
# Asset preflight — FAIL FAST, BEFORE ANY AZURE RESOURCE IS CREATED.
#
# On 2026-08-20 a dead image storage account (403 AccountIsDisabled) cost ~90
# minutes: azcopy failed silently in the VM, the checksum gate passed on two
# $null values, and the run died at the VHDX copy step with a misleading error.
# A later run then burned another ~60 minutes before Azure rejected the image
# with "Unsupported Azure Stack HCI OS Version".
#
# Everything below is a few seconds of curl. Keep it that way.
# =============================================================================
JS_AZLOCAL_IMAGE="${JS_AZLOCAL_IMAGE:-AzLocal2604}"
JS_GUI_IMAGE="${JS_GUI_IMAGE:-WinServerApril2024}"
AZLOCAL_BASE="https://jumpstartprodsg.blob.core.windows.net/jslocal/localbox/prod"
GUI_BASE="https://jumpstartprodsg.blob.core.windows.net/hcibox23h2"

check_asset() {
  # $1 = label, $2 = url. A ranged GET must return 206.
  code=$(curl -s -o /dev/null -w "%{http_code}" -r 0-100 --max-time 30 "$2" || echo "000")
  if [ "$code" != "206" ] && [ "$code" != "200" ]; then
    echo "ERROR: $1 is not retrievable (HTTP $code)" >&2
    echo "       $2" >&2
    echo "       A 403 AccountIsDisabled means that storage account is dead — find the" >&2
    echo "       image on another account and set JS_AZLOCAL_IMAGE / update the base URL" >&2
    echo "       in infra/artifacts/PowerShell/New-LocalBoxCluster.ps1." >&2
    return 1
  fi
  echo "    OK ($code): $1"
}

echo "==> Preflighting VHD image assets..."
preflight_failed=0
check_asset "AzLocal VHDX ($JS_AZLOCAL_IMAGE)"   "$AZLOCAL_BASE/$JS_AZLOCAL_IMAGE.vhdx"   || preflight_failed=1
check_asset "AzLocal SHA256 ($JS_AZLOCAL_IMAGE)" "$AZLOCAL_BASE/$JS_AZLOCAL_IMAGE.sha256" || preflight_failed=1
check_asset "GUI VHDX ($JS_GUI_IMAGE)"           "$GUI_BASE/$JS_GUI_IMAGE.vhdx"           || preflight_failed=1
check_asset "GUI SHA256 ($JS_GUI_IMAGE)"         "$GUI_BASE/$JS_GUI_IMAGE.sha256"         || preflight_failed=1

# ---- The VM downloads its automation from the fork, not from this repo. ----
# If the fork is unpushed or stale, the VM silently runs DIFFERENT code to what
# is checked out here — which is exactly how a patched fix gets "lost".
JS_GITHUB_ACCOUNT="${JS_GITHUB_ACCOUNT:-microsoft}"
JS_GITHUB_BRANCH="${JS_GITHUB_BRANCH:-main}"
TEMPLATE_BASE="https://raw.githubusercontent.com/${JS_GITHUB_ACCOUNT}/azure_arc/${JS_GITHUB_BRANCH}/azure_jumpstart_localbox"

echo "==> Verifying in-VM automation source ($JS_GITHUB_ACCOUNT/$JS_GITHUB_BRANCH)..."
remote_script=$(curl -s --max-time 30 -H 'Cache-Control: no-cache' \
  "${TEMPLATE_BASE}/artifacts/PowerShell/New-LocalBoxCluster.ps1?cb=$$" || echo "")

if [ -z "$remote_script" ]; then
  echo "ERROR: could not fetch New-LocalBoxCluster.ps1 from the fork." >&2
  echo "       $TEMPLATE_BASE" >&2
  preflight_failed=1
else
  # Guard 1: the hardened download helper must be present.
  if ! printf '%s' "$remote_script" | grep -q 'Invoke-VhdDownload'; then
    echo "ERROR: the fork is serving an UNPATCHED New-LocalBoxCluster.ps1" >&2
    echo "       (no Invoke-VhdDownload — azcopy failures will be silent again)." >&2
    echo "       Push infra/artifacts/PowerShell/ to ${JS_GITHUB_ACCOUNT}/azure_arc@${JS_GITHUB_BRANCH}." >&2
    echo "       NOTE: raw.githubusercontent.com caches for ~5 min after a push." >&2
    preflight_failed=1
  fi
  # Guard 2: no active azcopy line may reference the dead storage account.
  if printf '%s' "$remote_script" | grep -E '^\s*azcopy' | grep -q 'azlocalvhds'; then
    echo "ERROR: the fork still downloads from azlocalvhds.blob.core.windows.net (403)." >&2
    preflight_failed=1
  fi
  # Guard 3: the image the fork will pull must be the one we just preflighted.
  # Match the ACTIVE assignment, not prose — the file documents older image
  # names in comments and a naive substring match passes on those.
  if ! printf '%s' "$remote_script" | grep -qE "^\s*\\\$azLocalImage\s*=.*'${JS_AZLOCAL_IMAGE}'"; then
    echo "ERROR: fork does not actively pin AzLocal image '$JS_AZLOCAL_IMAGE'." >&2
    echo "       Active pin in the fork:" >&2
    printf '%s' "$remote_script" | grep -E "^\s*\\\$azLocalImage\s*=" | sed 's/^/         /' >&2
    echo "       The preflight above validated an image the VM will not actually use." >&2
    preflight_failed=1
  fi
  [ "$preflight_failed" -eq 0 ] && echo "    OK: fork serves the patched script pinned to $JS_AZLOCAL_IMAGE"
fi

if [ "$preflight_failed" -ne 0 ]; then
  echo "" >&2
  echo "Preflight failed. Nothing has been deployed. Fix the above and re-run." >&2
  exit 1
fi
azd env set JS_AZLOCAL_IMAGE "$JS_AZLOCAL_IMAGE"
echo "==> Asset preflight passed."

# ---- Windows admin username ----
JS_WINDOWS_ADMIN_USERNAME="${JS_WINDOWS_ADMIN_USERNAME:-arcdemo}"
read -r -p "Windows admin username [$JS_WINDOWS_ADMIN_USERNAME]: " promptOutput || true
[ -n "${promptOutput:-}" ] && JS_WINDOWS_ADMIN_USERNAME="$promptOutput"
azd env set JS_WINDOWS_ADMIN_USERNAME "$JS_WINDOWS_ADMIN_USERNAME"

# ---- Windows admin password (secure; stored in azd env) ----
if [ -z "${JS_WINDOWS_ADMIN_PASSWORD:-}" ]; then
  while true; do
    read -r -s -p "Windows admin password (12-123 chars, complexity): " pw1; echo
    read -r -s -p "Confirm password: " pw2; echo
    if [ "$pw1" = "$pw2" ] && [ "${#pw1}" -ge 12 ]; then
      azd env set JS_WINDOWS_ADMIN_PASSWORD "$pw1"
      break
    fi
    echo "Passwords did not match or too short; try again."
  done
fi

# ---- Microsoft.AzureStackHCI resource provider object id ----
if [ -z "${SPN_PROVIDER_ID:-}" ]; then
  echo "==> Resolving Microsoft.AzureStackHCI provider service principal object id..."
  spnProviderId=$(az ad sp list --display-name "Microsoft.AzureStackHCI" --query "[0].id" -o tsv 2>/dev/null || echo "")
  if [ -z "$spnProviderId" ]; then
    echo "ERROR: Could not resolve Microsoft.AzureStackHCI provider object id." >&2
    echo "Ask a tenant admin to run: az ad sp list --display-name 'Microsoft.AzureStackHCI' --query [0].id -o tsv" >&2
    echo "then: azd env set SPN_PROVIDER_ID <id>" >&2
    exit 1
  fi
  azd env set SPN_PROVIDER_ID "$spnProviderId"
fi

# ---- Deployment principal ----
# The deployment runs as the signed-in az/azd user (Owner on the subscription).
# No service principal is required: main.localbox.bicep passes only spnProviderId
# to the templates, and every role assignment in it targets the client VM's
# system-assigned managed identity (hostDeployment.outputs.vmPrincipalId), not an
# SP. SPN_CLIENT_ID / SPN_OBJECT_ID are therefore not read by any template and the
# gate that required them has been removed.

# Tenant id
if [ -z "${SPN_TENANT_ID:-}" ]; then
  azd env set SPN_TENANT_ID "$(az account show --query tenantId -o tsv)"
fi

echo "==> preprovision complete."
