<#
.SYNOPSIS
    Rewires PriceAdjustmentSchedule IDs in the pricing procedure XML for a target org.

.DESCRIPTION
    The pricing procedure XML contains three hardcoded PriceAdjustmentSchedule record IDs
    from the source 264 QuantumBit org. Every Salesforce org assigns different IDs to the
    same records. This script queries the target org for the three standard PAS records by
    name, then replaces the source-org IDs in the XML with the target-org IDs so the
    deployment wires up correctly.

    Run this BEFORE deploying. After running it, deploy with:
        sf project deploy start --source-dir force-app --target-org <alias>

    If you need to reset the XML back to the original source-org IDs (e.g. to run against
    a different target), run:
        git restore force-app/main/default/expressionSetDefinition/RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml

.PARAMETER TargetOrg
    The SF CLI org alias or username for the target org.

.EXAMPLE
    .\rewire-pas-ids.ps1 -TargetOrg my-new-quantumbit-org
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetOrg
)

$ErrorActionPreference = "Stop"

# Path to the pricing procedure XML relative to this script
$XmlPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "..\force-app\main\default\expressionSetDefinition\RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml")
)

if (-not (Test-Path $XmlPath)) {
    Write-Error "Pricing procedure XML not found at: $XmlPath"
    exit 1
}

Write-Host ""
Write-Host "Target org : $TargetOrg"
Write-Host "XML file   : $XmlPath"
Write-Host ""

# The three PAS record IDs hardcoded in the source (264 QuantumBit) org
$SOURCE_ATTR_ID   = "84Xbm0000010nmXEAQ"
$SOURCE_BUNDLE_ID = "84Xbm0000010nmYEAQ"
$SOURCE_VOLUME_ID = "84Xbm0000010nmZEAQ"

# Helper: run a SOQL query and return the Id of the first result
function Get-RecordId {
    param([string]$Org, [string]$Query, [string]$Label)
    $raw = sf data query --target-org $Org --query $Query --result-format json 2>&1
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "Failed to parse sf CLI output for '$Label'. Raw output: $raw"
        exit 1
    }
    if ($parsed.result.totalSize -eq 0) {
        Write-Error "No PriceAdjustmentSchedule found with name: $Label. Is this org a 264 QuantumBit org with RLM installed?"
        exit 1
    }
    return $parsed.result.records[0].Id
}

Write-Host "Querying PriceAdjustmentSchedule IDs from target org..."
$targetAttrId   = Get-RecordId -Org $TargetOrg -Query "SELECT Id FROM PriceAdjustmentSchedule WHERE Name = 'Standard Attribute Based Adjustment'" -Label "Standard Attribute Based Adjustment"
$targetBundleId = Get-RecordId -Org $TargetOrg -Query "SELECT Id FROM PriceAdjustmentSchedule WHERE Name = 'Standard Bundle Based Adjustment'" -Label "Standard Bundle Based Adjustment"
$targetVolumeId = Get-RecordId -Org $TargetOrg -Query "SELECT Id FROM PriceAdjustmentSchedule WHERE Name = 'Standard Price Adjustment Tier'" -Label "Standard Price Adjustment Tier"

Write-Host ""
Write-Host "  AttributePASIdConstant  : $SOURCE_ATTR_ID  ->  $targetAttrId"
Write-Host "  BundlePASIdConstant     : $SOURCE_BUNDLE_ID  ->  $targetBundleId"
Write-Host "  VolumePASIdConstant     : $SOURCE_VOLUME_ID  ->  $targetVolumeId"
Write-Host ""

# Check if any IDs actually differ
if ($targetAttrId -eq $SOURCE_ATTR_ID -and $targetBundleId -eq $SOURCE_BUNDLE_ID -and $targetVolumeId -eq $SOURCE_VOLUME_ID) {
    Write-Host "All IDs already match the source org. XML unchanged."
    exit 0
}

Write-Host "Updating XML..."
$content = [System.IO.File]::ReadAllText($XmlPath)

$content = $content.Replace($SOURCE_ATTR_ID,   $targetAttrId)
$content = $content.Replace($SOURCE_BUNDLE_ID, $targetBundleId)
$content = $content.Replace($SOURCE_VOLUME_ID, $targetVolumeId)

[System.IO.File]::WriteAllText($XmlPath, $content)

Write-Host "XML updated successfully."
Write-Host ""
Write-Host "Next: deploy to $TargetOrg"
Write-Host "  sf project deploy start --source-dir force-app --target-org $TargetOrg"
Write-Host ""
Write-Host "After deploy: activate v2 in the target org (see deployment-guide.md)."
Write-Host ""
Write-Host "To reset the XML back to source-org IDs before targeting a different org:"
Write-Host "  git restore force-app/main/default/expressionSetDefinition/RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml"
