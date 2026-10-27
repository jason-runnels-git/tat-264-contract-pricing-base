# Contract Pricing — Deployment Guide

**Applies to:** 264 QuantumBit orgs with RLM Release 264 / API v68.0
**Deploys:** Contract pricing changes (CHANGE 1–12) — pricing procedure v2, Before Save flow

---

## What gets deployed

| Component | Type | Location in repo |
|---|---|---|
| `RLM_DefaultPricingProcedure` v2 | ExpressionSetDefinition | `force-app/main/default/expressionSetDefinition/` |
| `RLM_Set_Pricing_Contract_On_Quote` | Flow (Before Save) | `force-app/main/default/flows/` |

The pricing procedure deploys as **Draft**. You activate it manually after deploy (Step 4).

---

## Prerequisites

- [SF CLI](https://developer.salesforce.com/tools/salesforcecli) installed (`sf --version` should return output)
- Authenticated to the target org: `sf org login web --alias <your-alias>`
- PowerShell 5.1+ (built into Windows 10/11)
- You are in the repo root directory: `C:\...\TAT_CONTRACT_PRICING`

---

## Step 1 — Authenticate to the target org

If you haven't already:

```powershell
sf org login web --alias my-target-org
```

Verify it worked:

```powershell
sf org display --target-org my-target-org
```

---

## Step 2 — Rewire PAS IDs for the target org

The pricing procedure XML has three hardcoded record IDs (for Price Adjustment Schedules) that are specific to the source 264 QuantumBit org. They will not match in a different org. Run this script to replace them with the target org's IDs:

```powershell
.\scripts\rewire-pas-ids.ps1 -TargetOrg my-target-org
```

The script will print the three ID replacements it made and confirm the XML was updated.

> **If deploying to multiple orgs in sequence:** After deploying to one org, restore the XML to the source IDs before running the script for the next org:
> ```powershell
> git restore force-app/main/default/expressionSetDefinition/RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml
> ```
> Then re-run the script with the next org alias.

---

## Step 3 — Deploy

```powershell
sf project deploy start --source-dir force-app --target-org my-target-org
```

Expected output: all components deploy successfully. The pricing procedure will show as **Draft** in the target org — that is correct.

> **If you see a warning about v1 already existing:** This is expected. The target org already has v1 from the base org build. The deploy updates v2 only. The warning can be ignored.

---

## Step 4 — Activate the pricing procedure v2

The pricing procedure must be activated through the Salesforce UI — the platform does not allow activating via metadata deploy.

1. In the target org, go to **Setup → Revenue Lifecycle Management → Pricing Procedures** (or search "Expression Sets" in Setup)
2. Click **RLM Revenue Management Default Pricing Procedure**
3. You will see two versions: **v1** (Inactive) and **v2** (Draft)
4. Click **Activate** on v2
5. Confirm when prompted — v2 becomes Active

> v1 should already be Inactive in this org (it was deactivated as part of the base org build). If v1 shows as Active, deactivate it first before activating v2.

---

## Step 5 — Verify the Before Save flow is active

1. In Setup, search **Flows**
2. Find **RLM Set Pricing Contract On Quote**
3. Confirm it shows **Active** status
4. If it shows Inactive, open it and click **Activate**

---

## Step 6 — Smoke test

1. Create or open a Quote with a product that has a `ContractItemPrice` record on an Activated contract
2. Set `ContractId` on the Quote (the Before Save flow auto-populates `PricingContractId`)
3. Save the Quote and reprice
4. Verify the Quote Line's `NetUnitPrice` reflects the CIP price (not the standard pricebook price)

For a bundle scenario: add a bundle child product that has an explicit `StartDate` and a matching CIP. Confirm `NetUnitPrice` = CIP price × (1 − bundle discount %).

---

## Rollback

If something goes wrong after activating v2:

1. Go to Setup → Expression Sets → RLM Revenue Management Default Pricing Procedure
2. Find v2 (Active) and click **Deactivate**
3. Find v1 (Inactive) and click **Activate** to restore the prior behavior

To restore the XML in the repo to the source-org IDs:

```powershell
git restore force-app/main/default/expressionSetDefinition/RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml
```

---

## What the CHANGE 1–12 modifications do

See [`v2-pricing-procedure-migration-runbook.md`](v2-pricing-procedure-migration-runbook.md) for the full change log. In summary:

| Change | What it does |
|---|---|
| CHANGE 1 | Propagates `PricingContractId` from Quote to all lines before any pricing runs |
| CHANGE 2–9 | Gates attribute pricing, volume discounts, and manual discounts to skip contracted lines |
| CHANGE 10A | Forces CIP list price to re-evaluate on amendment quotes where `PricingContractId` is set |
| CHANGE 11 | Ensures amendment lines with a contract override last-transaction pricing with CIP |
| CHANGE 12 | Excludes bundle children with null `StartDate` from CIP DT (prevents "duplicate entries" error) |
