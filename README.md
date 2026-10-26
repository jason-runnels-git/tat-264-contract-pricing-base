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
| `RLM_DefaultPricingProcedure` updated to V2 (9 changes) | ✅ Done — V2 active, 9 changes applied 2026-10-26 |
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

### Change 4 — Pricing Procedure V2 Migration (`RLM_DefaultPricingProcedure`)

V2 of the pricing procedure was created (Version Number: 2, Rank: 2) and all 9 changes below were applied before activation. V1 (Rank 1) was deactivated first. V2 is now the active version.

**File changed:** `force-app/main/default/expressionSetDefinition/RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml`

---

#### Procedure Change 1 — Add Assignment: Pass Pricing Contract ID from Quote to Lines

A new Assignment element (`PassPricingContractIDfromQuotetoQuoteLines`) was inserted at seq 3, immediately after the Map Line Items element. It copies the header-level `PricingContract` context variable (`Quote.PricingContractId`) into the line-level `ItemPricingContract` context variable (`QuoteLineItem.PricingContractId`) before any contract lookup runs.

**Why:** `QuoteLineItem.PricingContractId` is not automatically populated from the quote header. Every downstream contract element reads `ItemPricingContract` — without this assignment, the value is always null for direct-contract quotes.

---

#### Procedure Change 2 — Rename and Fix "Assigned From Pricing Contract" List Price Element

The List Price element inside **Set List Price for Lines With Contract Pricing** was originally named `Assign ItemContractPrice to ListPrice`. Two changes applied:

1. **Renamed** to `Assigned From Pricing Contract`
2. **ContractId input variable changed:** `ItemContract` → `ItemPricingContract`

**Why:** `ItemContract` is the platform-native variable for ARC amendment lines only — it is null for direct-contract quotes. Switching to `ItemPricingContract` (set by Procedure Change 1) enables the CIP decision table lookup for direct-contract quotes.

---

#### Procedure Change 3 — Fix Root-Cause Filter: Set List Price for Lines With Contract Pricing

The Filter element (seq 1) inside this conditional group had a circular dependency that permanently locked out all contract pricing:

| Old (3 conditions) | New (1 condition) |
|---|---|
| Item Pricing Source IS NULL | Item Pricing Contract IS NOT NULL |
| Is Contracted IS NOT NULL | — |
| Is Contracted EQUALS true | — |

**Why this was broken:** `IsContracted` starts null at the beginning of every pricing run. It is only set to `true` by the `Assigned From Pricing Contract` DT element that lives inside this same container at seq 2. The filter ran first (seq 1), so all lines were blocked before the DT fired. `IsContracted` was never set — and every downstream contract container is also gated on `IsContracted = true` — so the entire contract pricing waterfall was permanently locked for every run.

**Fix:** The new single condition `ItemPricingContract IS NOT NULL` fires on the variable already populated by Procedure Change 1, breaking the circular dependency.

---

#### Procedure Change 4 — Volume Discount: ContractId Input

Inside **Apply Volume Based Discounts to Lines With Contract and Without Derived Pricing**, the Volume Discount element's `Id` input was changed:

- `ItemContract` → `ItemPricingContract`

Same root cause as Procedure Change 2 — `ItemContract` is null for direct-contract quotes.

---

#### Procedure Change 5 — Contract Attribute Pricing Filter: Add IsContracted Gating

Inside **Set Attribute Based Pricing for Lines Without Derived Pricing**, the Filter element was extended from 4 to 6 conditions:

| # | Added Condition |
|---|---|
| 5 | Is Contracted — IS NOT NULL |
| 6 | Is Contracted — EQUALS true |

**Why:** Without these conditions, non-contracted lines could attempt attribute pricing via the contract attribute path. After Procedure Change 3 unlocks the contract waterfall, `IsContracted = true` is only set for lines with a confirmed CIP match, so these conditions correctly limit this container to contracted lines only.

---

#### Procedure Change 6 — Fallback InputUnitPrice Filter: Exclude Contracted Lines

Inside **Set Input Unit Price for Lines Without Derived Pricing or Last Transaction Pricing**, the Filter element was extended from 4 to 5 conditions:

| # | Added Condition |
|---|---|
| 5 | Is Contracted — EQUALS false |

**Why:** After contract pricing runs (Procedure Changes 1–5), contracted lines already have `InputUnitPrice` set from the CIP. Without this condition, contracted lines could re-enter this container and have `InputUnitPrice` overwritten with pricebook list price. `Equals false` (not `Is Null`) ensures null-`IsContracted` lines (standard + amendment) still pass through.

---

#### Procedure Change 7 — Per-Line Date Input for CIP Date-Range Lookup

Inside **Assigned From Pricing Contract** (the List Price element), the StartDate and EndDate decision table inputs were changed:

| Input Column | Old | New |
|---|---|---|
| StartDate | `PricingDate` | `DerivedStartDateTime__std` |
| EndDate | `PricingDate` | `DerivedStartDateTime__std` |

**Why:** `PricingDate` resolves at header scope — all lines get the same date regardless of their individual `StartDate` values, so all lines matched the same CIP tier. `DerivedStartDateTime__std` is a platform-standard per-line `SalesTransactionItem` field derived from `QuoteLineItem.StartDate + StartTime`. Inside a List Price element (which executes per-line), it resolves at line scope — each line's CIP lookup uses its own start date, enabling multi-year date-range CIPs on a single quote.

---

#### Procedure Change 8 — Fix CIP Price Propagation to InputUnitPrice (Three-Part Fix)

**Root cause:** The `Assigned From Pricing Contract` DT correctly found the right CIP per line, but the matched price was not reaching each line's `InputUnitPrice` (Sales Price).

**Part A — Change DT Output: ListPrice → InputUnitPrice**

Inside the **Assigned From Pricing Contract** List Price element, the Output Variables mapping was changed:

- `ListPrice` output column: `ItemContractPrice` → `InputUnitPrice`

The List Price element's implicit platform behavior also writes the matched CIP price to the line's per-line `ListPrice` field as each line executes.

**Part B — Simplify Seq 11 Filter**

Inside **Set Input Unit Price for Lines With Contract Pricing**, the Filter element was simplified from 4 conditions to 2:

| Old (4 conditions, `1 AND (2 OR (3 AND 4))`) | New (2 conditions, `1 AND 2`) |
|---|---|
| Item Contract Price IS NOT NULL | Item Contract Price IS NOT NULL |
| Input Unit Price IS NULL | Input Unit Price IS NULL |
| List Price IS NOT NULL | *(removed)* |
| Input Unit Price EQUALS ListPrice | *(removed)* |

**Part C — Change Assignment Source: ItemContractPrice → ListPrice**

Inside **Set Input Unit Price for Lines With Contract Pricing**, the Assignment element was updated:

- **Label:** `Assign ItemContractPrice to InputUnitPrice` → `Assign ListPrice to InputUnitPrice`
- **Source variable:** `ItemContractPrice` → `ListPrice`

**Why Part C is the real fix:** `ItemContractPrice` is a transient procedure-level variable — it holds the last DT write across all lines in the batch (last-write-wins at header scope). After all contracted lines execute through the CIP container, `ItemContractPrice` reflects only the last line's price. The Assignment would then apply that single value to all lines. `ListPrice` is a per-line `SalesTransactionItem` field — the List Price BKM's implicit platform behavior writes each line's matched CIP price to its own `ListPrice` during the CIP lookup. Reading `ListPrice` in the Assignment gives each line its own correct per-line CIP price.

---

#### Procedure Change 9 — Rename Manual Discount Element for Waterfall Clarity

Inside **Apply manual discounts to lines without derived pricing**, the Manual Discount element was renamed:

- `Calculate net unit and item net total prices after manual discount` → `Discount Assigned From Pricing Contract`

Display-only change — no logic modified. Makes the pricing waterfall view accurately reflect that this element applies the contract-sourced discount for percentage and amount CIP types.

---

## Remaining Work

| Item | Notes |
|---|---|
| Contract Pricing Entries DT verification | Confirm source criteria, row count, and `LastSyncDate` in org |
| End-to-end test | Create contract + CIPs → activate → reprice quote → verify Sales Price |
| Amendment scenarios | Test 4 untested amendment scenarios from the table in this README |

---

## Repository Structure — Delta Files

```
_CONTRACT_PRICING_REFERENCE/                                    ← design docs (not deployed)
  Contract-Based-Pricing-in-QuantumBit-264.md
  flow-set-pricing-contract-on-quote.md
  v2-pricing-procedure-migration-runbook.md

force-app/main/default/
  expressionSetDefinition/
    RLM_DefaultPricingProcedure.expressionSetDefinition-meta.xml ← MODIFIED (Change 4 — V2, 9 procedure changes)
  flows/
    RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml              ← NEW (Change 2)
  permissionsets/
    RLM_QuantumBit.permissionset-meta.xml                        ← MODIFIED (Change 1)
  profiles/
    *.profile-meta.xml (75 files)                                ← NEW (Change 1)

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
