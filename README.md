# Contract-Based Pricing in QuantumBit (Release 264)

**Audience:** Solution Engineers evaluating or demonstrating contract pricing capabilities in a Release 264 org running Revenue Lifecycle Management (RLM).

This repository tracks the metadata changes applied to the `tat-264-contract-pricing` org to enable native contract-based pricing. All changes are deployed on top of the [rlm-base-dev](https://github.com/bgaldino/rlm-base-dev) Revenue Cloud Foundations Launchpad baseline (`upstream` remote).

---

## Overview

Release 264 (API v68.0) introduces a native contract pricing path in RLM that allows negotiated prices to be stored on a Contract and automatically applied when repricing a Quote. When a Quote is linked to a Contract, the pricing procedure looks up per-product, per-PSM prices from `ContractItemPrice` records and applies them as the Sales Price on each Quote Line.

The key new field enabling this is **`Quote.PricingContractId`** — a lookup to Contract introduced in Release 264. This field drives the contract pricing path in the pricing procedure. It is distinct from the older `Quote.ContractId` field and must be populated for contract pricing to work.

---

## Target Org

| Field | Value |
|---|---|
| **Alias** | `tat-264-contract-pricing` |
| **Instance** | `https://trailsignup-7230ff3f6f8437.my.salesforce.com` |
| **Username** | `trailsignup.7230ff3f6f8437@salesforce.com` |
| **API version** | 68.0 (Release 264 / Winter '27) |

---

## Supported Use Cases

Contract-based pricing in QuantumBit supports three distinct pricing modes through the `ContractItemPrice` framework. All three use the same Contract + `ContractItemPrice` data model and the same pricing procedure path — the difference is in the `DiscountType` field on the CIP record and how the price waterfall presents the result.

### Supported CIP Types

| CIP Type | `DiscountType` Value | How It Works in the Waterfall | Waterfall Display |
|---|---|---|---|
| **Contract Price (Fixed)** | `Price` | List Price lookup is bypassed. The CIP price is applied directly as Sales Price via the **Assigned From Pricing Contract** List Price element. | List Price shows with strikethrough; **Price Assigned from Pricing Contract** shows the negotiated price |
| **Contract Discount % (Percentage)** | `Percentage` | Standard List Price is retrieved first. The contract discount percentage is then applied via the **Discount Assigned From Pricing Contract** discount element. | List Price shows normally; **Discount Assigned from Pricing Contract** shows the % discount applied |
| **Contract Discount Amount (Fixed Amount)** | `Amount` | Standard List Price is retrieved first. The contract discount amount is subtracted via the **Discount Assigned From Pricing Contract** discount element. | List Price shows normally; **Discount Assigned from Pricing Contract** shows the amount discount applied |

### Use Case Examples

| Business Scenario | CIP Type to Use | Notes |
|---|---|---|
| Customer has a negotiated fixed price for a product, regardless of list price | Contract Price (Fixed) | Best for multi-year deals where the exact Sales Price is agreed upon. Year-over-year price changes use separate CIP rows with non-overlapping date ranges. |
| Customer has a negotiated % discount off list price | Contract Discount % | List price changes (e.g., annual price increases) automatically flow through; the discount percentage stays constant. |
| Customer has a negotiated flat dollar discount off list price | Contract Discount Amount | Useful when the discount is a fixed concession rather than a percentage relationship. |
| CONCEPTUAL: Partner pricing / channel discount | Contract Discount % or Amount | The same `ContractItemPrice` framework applies — link the partner's contract to the quote to apply their negotiated discount automatically. Standard contract pricing filters and procedure path are used unchanged. |
| Multi-year deal with different prices per year | Contract Price (Fixed), one CIP per year | Use non-overlapping StartDate/EndDate ranges per CIP row. Contract term must span all years. Line StartDate determines which CIP year matches. |
| Renewal with price protection | Contract Price (Fixed) | Set CIP price = prior-year Sales Price. Renewal quote lines with StartDates in the contract period resolve to the protected price automatically. |

---

## How It Works — End to End

### 1. Link a Contract to the Quote

Set `ContractId` on the Quote record. A Before Save flow (`RLM_Set_Pricing_Contract_On_Quote`) automatically keeps `PricingContractId` in sync with `ContractId` on every quote save — including when `ContractId` is cleared to null. No manual population of `PricingContractId` is required.

> **Note:** After saving a `ContractId` change, the Quote page may briefly show an orange stale-data warning. This is a known UI behavior — the record is correct in the database. The banner clears on the next reprice or manual page refresh.

### 2. Pricing Procedure Propagates Contract ID to Lines

On every reprice, the pricing procedure (seq 3) copies `Quote.PricingContractId` down to all `QuoteLineItem.PricingContractId` fields before any lookup runs. This ensures every line carries the contract identity into the CIP decision table lookup.

### 3. Contract Pricing Entries Lookup

For each line where `QuoteLineItem.PricingContractId` is not null, the procedure looks up a matching `ContractItemPrice` record from the **Contract Pricing Entries** decision table using:

| Input | Required? | Match |
|---|---|---|
| ContractId | Required | Equals |
| ItemId (Product) | Required | Equals |
| ProductSellingModelId | Required | Equals |
| SellingModelType | Optional | Equals |
| StartDate (line) | Required | ≥ CIP StartDate |
| EndDate (line) | Optional | ≤ CIP EndDate |
| CurrencyIsoCode | Required | Equals |

If a match is found, `IsContracted` is set to `true` for the line and the CIP price is applied as the Sales Price. Lines with no CIP match fall through to standard pricebook pricing.

### 4. Multi-Year / Date-Range CIPs

The procedure uses the line's `StartDate` (via `DerivedStartDateTime__std`) as the date input to the CIP lookup — not the quote header date. This means a single quote can have lines spanning multiple contract years and each line will resolve to the correct CIP tier for its own start date independently.

### 5. Contract Pricing Interaction with Other Pricing Paths

| Quote Line Condition | Pricing Path Applied |
|---|---|
| `PricingContractId` set + CIP match found | Contract pricing (CIP price → Sales Price) |
| `PricingContractId` set + no CIP match | Standard pricebook pricing |
| Amendment line (`ItemPricingSource = LastTransaction`) + no `PricingContractId` | Last Transaction price (asset-derived) |
| Amendment line + `PricingContractId` set + CIP match | Contract pricing overrides Last Transaction |
| Standard line, no contract | Pricebook → attribute adjustments → volume discounts |

### 6. Amendment Quotes and Contract Pricing — Tested and Untested Scenarios

**Tested and confirmed:**
- A standalone asset (no contract on the original quote) generates a mid-term amendment quote with `ItemPricingSource = LastTransaction`. Without a `ContractId` on the amendment quote, Last Transaction pricing applies correctly.
- Manually setting `ContractId` on that amendment quote causes `PricingContractId` to be populated by the Before Save flow. On reprice, contract pricing correctly overrides the Last Transaction price where a CIP match exists.

**Not yet tested — verify before demoing:**

| Scenario | Expected Behavior | Verified? |
|---|---|---|
| Amendment quote from asset with original contract — no changes to quote | Contract pricing applies automatically on reprice | ❌ Not tested |
| Amendment quote from asset with original contract — user clears `ContractId` | Before Save flow sets `PricingContractId = null`; Last Transaction pricing applies | ❌ Not tested |
| Amendment quote from asset with original contract — user changes to a different `ContractId` | Before Save flow updates `PricingContractId`; new contract's CIPs apply on reprice | ❌ Not tested |
| Amendment quote from asset with original contract — original contract has no CIPs | `PricingContractId` is set but no CIP match → falls through to Last Transaction pricing | ❌ Not tested |

---

## Setting Up Contract Item Prices — Manual Setup Requirements

When manually creating `ContractItemPrice` records (rather than using the "Create Contract from Quote" flow), the following requirements must all be met for the pricing procedure to find and apply the CIP:

### 1. The Contract Must Be Activated

The Contract Pricing Entries decision table only includes rows from Activated contracts. A `ContractItemPrice` under a Draft or In Approval contract is invisible to pricing. Activate the contract before testing any CIP lookup.

### 2. CIP Dates Must Fall Within the Contract's Own Start/End Dates

The `ContractItemPrice` effective dates (`StartDate`, `EndDate`) must be within the contract's own `StartDate` and `EndDate`. CIP rows with dates outside the contract period are excluded by the platform and will not appear in the decision table lookup regardless of activation status.

**Example:** To demonstrate CIP Year 1 = $1,500 and CIP Year 2 = $2,000 for the same product:
- Contract: `StartDate = Jan 1 2026`, `EndDate = Dec 31 2027` (24-month term)
- CIP 1: `StartDate = Jan 1 2026`, `EndDate = Dec 31 2026` → $1,500
- CIP 2: `StartDate = Jan 1 2027`, `EndDate = Dec 31 2027` → $2,000

A quote line with `StartDate` in 2026 resolves to $1,500. A quote line with `StartDate` in 2027 resolves to $2,000. Both work correctly in the same reprice because the procedure uses each line's own `StartDate` for the CIP lookup.

### 3. The Decision Table Must Be Refreshed After Activation

The Contract Pricing Entries decision table is a cached lookup — it does not query live records on every pricing run. It must be explicitly refreshed to pick up new or changed `ContractItemPrice` rows.

The flow `RLM_Contract_Activation_Refresh_Pricing_Tables` handles this automatically: it fires after every Contract save where `StatusCode` changes to `Activated` and refreshes all three contract pricing decision tables in sequence (`Contract_Pricing_Entries_Decision_Table`, `Contract_Pricing_Adjustment_Tiers`, `Contract_Pricing_Volume_Tiers`).

### 4. Product + PSM Must Match Exactly

Each `ContractItemPrice` row is matched by exact `ItemId` (Product) + `ProductSellingModelId` combination. There is no wildcard or inheritance — a CIP for Product A with PSM Annual will not match a line for Product A with PSM Monthly.

---

## Creating a Contract from a Quote

The `RLM CreateContractFromQuote` flow is invoked from the Quote record via the **New Contract** button. It presents three options:

| Option | What Gets Created |
|---|---|
| Net Unit Price | Contract header + one `ContractItemPrice` per quote line, using the line's `NetUnitPrice` as the CIP price |
| Discount | Contract header + one `ContractItemPrice` per quote line, using the line's discount |
| None | Contract header only — no `ContractItemPrice` records created |

After the contract is created, the flow sets `Contract.PricingSource = LastTransaction` and calculates the contract term and renewal term from the quote's line dates.

---

## Known Gaps and Limitations

### Gap 1: Product Category CIPs Are Not Supported

The Contract Pricing Entries decision table requires `ProductSellingModelId` as a Required Equals input. A category-level price rule has no PSM — it is intended to apply to all products in a category regardless of their selling model.

**Why a workaround is required:**
- Leaving `ProductSellingModelId` blank on a `ContractItemPrice` row does not act as a wildcard. A blank value only matches when the lookup input is also blank — which never occurs on a real quote line.
- This cannot be resolved by any pricing procedure change. The PSM requirement is structural to the decision table.

**Supported workaround — Generator Pattern:** At contract activation time, a generator process walks `ProductCategoryProduct` to find all products in the category, then walks `ProductSellingModelOption` for each product to get active PSMs, and creates one `ContractItemPrice` row per product + PSM combination. The pricing procedure requires no changes. Generated rows should be tagged with a custom field (e.g., `SourceType__c = 'CategoryGenerated'`) to distinguish them from manually entered product-level CIPs. Manual product CIPs take precedence via a narrower effective window.

### Gap 2: Volume Tier Records Are Not Auto-Generated at Contract Creation

The Contract Pricing Volume Tiers decision table sources from `ContractItemPriceAdjTier` — a child object of `ContractItemPrice` with fields `LowerBound`, `UpperBound`, `TierType`, and `TierValue`.

The `createContract` platform invocable (called by the Create Contract from Quote flow) creates `ContractItemPrice` records but does not create `ContractItemPriceAdjTier` records. No automation in the standard platform populates tier records from the source quote line's `PriceAdjustmentTier` data.

**Impact:** Volume-based contract discounts require `ContractItemPriceAdjTier` records to be created manually or via custom automation after contract creation and before activation. Without them, the Contract Pricing Volume Tiers DT returns no match for any quantity and no volume discount is applied.

**Additional constraint:** Both tier DTs (`Contract_Pricing_Adjustment_Tiers` and `Contract_Pricing_Volume_Tiers`) filter on `ContractItemPriceId.ContractId.StatusCode = Activated`. Tier rows that exist under a Draft contract are excluded from the DT — the table must be refreshed after activation (handled automatically by `RLM_Contract_Activation_Refresh_Pricing_Tables`).

### Gap 3: Bundle Child Lines — CIP Behavior Unconfirmed

Whether the `createContract` platform action creates `ContractItemPrice` records for bundle child `QuoteLineItem` records has not been confirmed. If bundle children are skipped, contract pricing will not apply to child lines. This needs testing before deploying contract pricing into a bundle-heavy catalog.

### Gap 4: Delta Quantity = 0 on Amendment Lines

On mid-term amendment quotes, a line with no quantity change (delta qty = 0) may not resolve `DerivedStartDateTime__std` correctly, causing the CIP date-range lookup to fail or return the wrong tier. Changing the line's quantity to a non-zero delta value resolves the issue. A documented platform fix involving the Map Line element and additional settings is pending documentation and has not yet been implemented.

---

## Decision Table Reference

| Decision Table | Source Object | Refresh Trigger |
|---|---|---|
| `Contract_Pricing_Entries_Decision_Table` | `ContractItemPrice` | Contract → Activated (auto via `RLM_Contract_Activation_Refresh_Pricing_Tables`) |
| `Contract_Pricing_Adjustment_Tiers` | `ContractItemPriceAdjTier` | Contract → Activated (auto via flow); filters on `StatusCode = Activated` |
| `Contract_Pricing_Volume_Tiers` | `ContractItemPriceAdjTier` | Contract → Activated (auto via flow); filters on `StatusCode = Activated` |

---

## Quick Reference — Setup Checklist

| Item | Status in this org |
|---|---|
| `Quote.PricingContractId` visible and editable for all profiles | ✅ Done — all 75 profiles + `RLM_QuantumBit` perm set |
| `QuoteLineItem.PricingContractId` visible and editable for all profiles | ✅ Done — all 75 profiles + `RLM_QuantumBit` perm set |
| `RLM_Set_Pricing_Contract_On_Quote` Before Save flow active | ✅ Done — verified live |
| `PricingContractId` on Quote page layout | ✅ Done — `Quote-RLM Quote Layout`, below `ContractId` |
| `PricingContractId` on Quote Lightning record page | ✅ Done — `RLM_Quote_Record_Page`, below `ContractId` |
| `PricingContractId` on Quote Line Item page layout | ✅ Done — `QuoteLineItem-RLM Quote Line Item Layout`, after `ListPrice` |
| `RLM_DefaultPricingProcedure` updated to V2 (8 changes) | ⏳ Pending |
| Contract has `ContractItemPrice` records for each product + PSM | Runtime — per scenario |
| CIP `StartDate`/`EndDate` within contract's own dates | Runtime — per scenario |
| Contract is Activated | Runtime — per scenario |
| `Contract_Pricing_Entries_Decision_Table` refreshed after activation | Runtime — auto via `RLM_Contract_Activation_Refresh_Pricing_Tables` |
| Quote has `ContractId` set (flow auto-populates `PricingContractId`) | Runtime — per scenario |
| Quote repriced after contract linkage | Runtime — per scenario |

---

## Org Changes — Deployed 2026-10-26

### Change 1 — Field-Level Security: `Quote.PricingContractId` and `QuoteLineItem.PricingContractId`

`PricingContractId` was introduced in Release 264. It is not visible or editable by default on any profile. This change grants Read + Edit FLS across the org.

**Files changed:**

- `force-app/main/default/permissionsets/RLM_QuantumBit.permissionset-meta.xml` — added `editable: true / readable: true` for `Quote.PricingContractId` and `QuoteLineItem.PricingContractId`
- `force-app/main/default/profiles/*.profile-meta.xml` — 75 minimal partial-profile files created, each granting `editable: true / readable: true` for both fields (additive deployment — no existing permissions removed)

**Deploy result:** 76 components deployed, 0 errors, status: Succeeded.

---

### Change 2 — Before Save Flow: `RLM_Set_Pricing_Contract_On_Quote`

`PricingContractId` is the field the pricing procedure reads. `ContractId` is the field users and the ARC engine set. This Before Save flow keeps them in sync on every quote save so no manual field population is required.

**File created:** `force-app/main/default/flows/RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml`

| Property | Value |
|---|---|
| Object | `Quote` |
| Type | Record-Triggered Flow — Before Save |
| Fires on | Create and Update |
| Entry condition | `{!$Record.PricingContractId} != {!$Record.ContractId}` |
| Action | Assigns `$Record.PricingContractId = $Record.ContractId` |
| Status | Active |
| API version | 68.0 |

**Behavior matrix:**

| `ContractId` | `PricingContractId` before | Flow fires? | `PricingContractId` after |
|---|---|---|---|
| null | null | No — `null != null` is false | null (unchanged) |
| `800Wt…` | null | Yes | `800Wt…` (set) |
| `800Wt…` | `800Wt…` (same value) | No | unchanged |
| `800Wt…B` | `800Wt…A` (different value) | Yes | `800Wt…B` (updated) |
| null | `800Wt…` (cleared) | Yes | null (cleared) |

**Note:** Before Save flows run in system context — FLS on the running user does not affect whether the flow executes or whether it can write `PricingContractId`.

**Deploy result:** 1 Flow component created, 0 errors, status: Succeeded.  
**Live verification:** `FlowDefinitionView` confirmed `TriggerType: RecordBeforeSave`, `RecordTriggerType: CreateAndUpdate`, `IsActive: true`.

---

### Change 3 — Page Layouts and Lightning Record Page

`PricingContractId` must appear on page layouts and the RLM Lightning record page so users and SEs can see the contract context the pricing procedure is using.

**How changes are made in this repo:** The `unpackaged/post_ux/` directory is auto-generated — never hand-edited. All changes go in `templates/`, then `python scripts/ux/ux_tool.py assemble` regenerates `unpackaged/post_ux/`.

**Templates edited:**

| Template file | Change |
|---|---|
| `templates/layouts/base/Quote-RLM Quote Layout.layout-meta.xml` | Added `PricingContractId` (Edit behavior) immediately after `ContractId` |
| `templates/layouts/base/QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml` | Added `PricingContractId` (Edit behavior) after `ListPrice` |
| `templates/layouts/constraints/QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml` | Same — the constraints template overrides the base for QuoteLineItem; both must be updated |
| `templates/flexipages/base/RLM_Quote_Record_Page.flexipage-meta.xml` | Added `Record.PricingContractId` field component (`identifier: RecordPricingContractIdField`, `uiBehavior: none`) immediately after `Record.ContractId` |

**Regeneration:** `python scripts/ux/ux_tool.py assemble` rebuilt all 114 items in `unpackaged/post_ux/`.

**Components deployed:**

| Component | Type | Result |
|---|---|---|
| `Quote-RLM Quote Layout` | Layout | Changed |
| `QuoteLineItem-RLM Quote Line Item Layout` | Layout | Changed |
| `RLM_Quote_Record_Page` | FlexiPage | Changed |

**Deploy result:** 3 components deployed, 0 errors, status: Succeeded.

---

## Remaining Work

| Item | Notes |
|---|---|
| **V2 pricing procedure migration** (8 changes to `RLM_DefaultPricingProcedure`) | Root cause fixes for contract pricing path — CHANGE 1 through CHANGE 8 per `_CONTRACT_PRICING_REFERENCE/v2-pricing-procedure-migration-runbook.md` |
| Contract Pricing Entries DT verification | Confirm source criteria, row count, and `LastSyncDate` in org |
| End-to-end test | Create contract + CIPs → activate → reprice quote → verify Sales Price |

---

## Repository Structure — Delta Files

```
_CONTRACT_PRICING_REFERENCE/                                    ← design docs (not deployed)
  Contract-Based-Pricing-in-QuantumBit-264.md
  flow-set-pricing-contract-on-quote.md
  v2-pricing-procedure-migration-runbook.md

force-app/main/default/
  flows/
    RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml             ← NEW (Change 2)
  permissionsets/
    RLM_QuantumBit.permissionset-meta.xml                       ← MODIFIED (Change 1)
  profiles/
    *.profile-meta.xml (75 files)                               ← NEW (Change 1)

templates/
  flexipages/base/
    RLM_Quote_Record_Page.flexipage-meta.xml                    ← MODIFIED (Change 3)
  layouts/base/
    Quote-RLM Quote Layout.layout-meta.xml                      ← MODIFIED (Change 3)
    QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml    ← MODIFIED (Change 3)
  layouts/constraints/
    QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml    ← MODIFIED (Change 3)
```

All other files are inherited unchanged from [bgaldino/rlm-base-dev](https://github.com/bgaldino/rlm-base-dev) (`upstream` remote).

---

## Skills Reference

Skills for working with this org are in `.cursor/skills/`. Key skills for contract pricing:

| Skill | Path |
|---|---|
| Expression sets / pricing procedures | `.cursor/skills/expression-sets/SKILL.md` |
| Decision tables | `.cursor/skills/decision-tables/SKILL.md` |
| Salesforce Contracts (CLM) | `.cursor/skills/salesforce-contracts/SKILL.md` |
| Pricing wiring | `.cursor/skills/pricing-wiring/SKILL.md` |
| Troubleshooting | `.cursor/skills/troubleshooting/SKILL.md` |

---

## License

Apache License, Version 2.0 — see [LICENSE.txt](LICENSE.txt).
