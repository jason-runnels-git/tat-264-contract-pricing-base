# Pre-Negotiated Contract Pricing — Architecture Design
**Org:** QuantumBit 264 (trailsignup-1030e9ecc9f5b3.my.salesforce.com, API v68.0 / Release 264.8.101)**
**Date:** 2026-10-13

---

## Objective

Design a flexible framework for pre-negotiated contract pricing in Salesforce Revenue Cloud (RLM) supporting:
1. Quantity-based cumulative tier discounts applied at the product family level
2. Attribute-based price overrides for specific products
3. Enterprise-grade extensibility for future patterns

---

## Data Model

```
Contract (IsPricingContract=true, StatusCode=Activated, AggregationStrategy=Cumulative)
  └── ContractItemPrice (ContractId, ItemId=Product2, AdjustmentMethod=Range|Slab)
        └── ContractItemPriceAdjTier (TierType, LowerBound, UpperBound, TierValue)

PriceAdjustmentSchedule (ContractId, ScheduleType=Attribute)
  └── AttributeBasedAdjRule → AttributeAdjustmentCondition
        └── AttributeBasedAdjustment
```

### ContractItemPrice Field Reference
| Field | Type | Notes |
|---|---|---|
| ContractId | Reference | The pricing contract |
| ItemId | Polymorphic Reference | Product2 only (see ProductCategory gap below) |
| ProductSellingModelId | Reference | Optional — scope to selling model |
| AdjustmentMethod | Picklist | Range (single bracket) or Slab (slice-by-slice) |
| Price | Currency | Net unit price override (no tiers needed) |
| DiscountType | Picklist | AdjustmentPercentage or AdjustmentAmount |
| DiscountValue | Double | Flat discount when no tiers used |
| ListPrice | Currency | Baseline list for override context |
| StartDate / EndDate | Datetime | Date-range validity |

### ContractItemPriceAdjTier Field Reference
| Field | Type | Notes |
|---|---|---|
| ContractItemPriceId | Reference | Parent CIP |
| TierType | Picklist | AdjustmentPercentage, AdjustmentAmount, OverrideAmount |
| LowerBound | Double | Quantity lower bound (inclusive) |
| UpperBound | Double | Quantity upper bound; null = open-ended top tier |
| TierValue | Double | The discount value or override amount |

---

## Activation Chain

```
Quote.PricingContractId
  └── QuoteLineItem.PricingContractId (propagated from header)
        └── ItemContract context variable
              └── Contract_Pricing_Entries_Decision_Table
                    ├── sets IsContracted = true
                    ├── outputs ItemContractPrice, ItemContractDiscount
                    └── outputs ItemContractAttributePasId (for attribute path)
```

- `Quote.PricingContractId` ≠ `Quote.ContractId` — a quote can relate to one CRM contract and be priced by a different pricing contract.
- Contract must have `StatusCode = Activated` — hard pre-filter on all three contract pricing decision tables.
- **`Quote.PricingContractId` is the INPUT; `QuoteLineItem.PricingContractId` is the OUTPUT.** `RLM_SalesTransactionContext` maps `Quote.PricingContractId` into the `ItemContract` context variable, which propagates to each line during pricing. The line does not need to know the contract in advance — the context carries it. After the DT matches a CIP and `IsContracted=true`, the procedure writes `QuoteLineItem.PricingContractId` back to the line as an attribution field. FLS must allow Edit on both Quote and QuoteLineItem `PricingContractId` — without it the write to the line silently fails and the waterfall cannot attribute correctly.

---

## Pricing Procedure Decision Tables

Three decision tables in `NGPDefaultRecipe` / `RLM_DefaultPricingProcedure`:

| Table | Source Object | Pre-filter | Use Case |
|---|---|---|---|
| `Contract_Pricing_Entries_Decision_Table` | ContractItemPrice | StatusCode=Activated | Match product → set IsContracted, output price/discount |
| `Contract_Pricing_Volume_Tiers` | ContractItemPriceAdjTier | AdjustmentMethod=Range, StatusCode=Activated | Single bracket — applies to full quantity |
| `Contract_Pricing_Adjustment_Tiers` | ContractItemPriceAdjTier | AdjustmentMethod=Slab, StatusCode=Activated | All brackets returned for slice-by-slice calc |

- `filterResultBy = OutputOrder`, `isBestFitEnabled = false` — no automatic Product2 vs. ProductCategory precedence.
- `doesConsiderNullValue = true` — null UpperBound matches as open-ended top tier.

**DT refresh is automatic on activation.** `RLM_Contract_Activation_Refresh_Pricing_Tables` is a record-triggered flow that fires when `Contract.StatusCode` transitions to `Activated` and refreshes all three contract pricing decision tables. Manual DT refresh is not required after activation — it is redundant. If this flow is missing from an org, tables must be refreshed manually via Setup → Decision Tables.

**Manual DT refresh mechanics (when needed).** Fire via `GET /services/data/v68.0/connect/core-pricing/sync/syncData`. The query param `pricingSyncOrigin` must equal `syncData` exactly — any other value silently returns `success:false`. The `200 { "success": true }` response means **accepted, not done** — the refresh is async. Poll `DecisionTable` records (`RefreshStatus`, `LastSyncDate`) to confirm real completion. Rate limit: **40 refreshes/hr per DT** (low-volume/standard), 60/hr medium. A recipe-wide sync touches every active DT (~9+), so a single recipe-wide run burns ~9 units against the 40/hr budget. There is no API to read the current hourly counter; a `success:false` with an "N refreshes per hour" error is the rate-limit signal — stop and surface it to the user.

---

## Supported Patterns (Today)

### Pattern 1 — Volume Tier Discounts (Product Level)
*Qty-based cumulative tiers applied to individual products*

```
Contract
  AggregationStrategy = Cumulative

ContractItemPrice (per product)
  ItemId           = QB Enterprise (Product2)
  AdjustmentMethod = Slab
  DiscountType     = AdjustmentPercentage

  ContractItemPriceAdjTier #1: LowerBound=1000,  UpperBound=4999,  TierValue=10
  ContractItemPriceAdjTier #2: LowerBound=5000,  UpperBound=9999,  TierValue=20
  ContractItemPriceAdjTier #3: LowerBound=10000, UpperBound=null,  TierValue=25
```

Repeat the ContractItemPrice + 3 tiers for each product in the target family.

**Cumulative behavior:** Quantity across all lines (and across existing orders when AggregationStrategy=Cumulative) aggregates into `AggregatedQuantity_std`. The Slab table returns all tier boundaries; the procedure calculates slice-by-slice discounts.

**Known gotcha:** "Duplicate entries found while looking up VolumeDiscount" error occurs when bounds are mapped to `AggregatedQuantity_std` but no pricing contract is on the quote (aggregated qty returns null). Ensure `Quote.PricingContractId` is always set before pricing runs.

---

### Pattern 2 — Attribute-Based Price Overrides (Product Level)
*Fixed price by product configuration attribute (e.g., bronze/silver/gold)*

```
PriceAdjustmentSchedule
  ContractId       = [PricingContract]
  ScheduleType     = Attribute
  AdjustmentMethod = Range

AttributeBasedAdjRule "Tier Override"
  └── AttributeAdjustmentCondition: ProductTier = "bronze"
  └── AttributeBasedAdjustment: TierType=OverrideAmount, TierValue=10000

AttributeBasedAdjRule "Tier Override"
  └── AttributeAdjustmentCondition: ProductTier = "silver"
  └── AttributeBasedAdjustment: TierType=OverrideAmount, TierValue=12000

AttributeBasedAdjRule "Tier Override"
  └── AttributeAdjustmentCondition: ProductTier = "gold"
  └── AttributeBasedAdjustment: TierType=OverrideAmount, TierValue=15000

ContractItemPrice
  ContractId       = [PricingContract]
  ItemId           = [specific Product2]
  AdjustmentMethod = Range
  (procedure links via ItemContractAttributePasId context variable)
```

**Needs live test:** Exact linkage between CIP and the contract-scoped PAS — whether it's a direct CIP field or a procedure-level join — must be verified in Phase 1.

---

### Pattern 3 — Simple Net Price Override
*Lock in a specific net unit price, no tiers*

```
ContractItemPrice
  ContractId  = [PricingContract]
  ItemId      = [Product2]
  Price       = 50000
```

The procedure step "Assign ItemContractPrice to InputUnitPrice" applies the `Price` field directly. This is what the native "Create Contract" UI action generates.

---

## Known Gaps

### Gap 1 — ProductCategory Scope (Critical)
**Status:** Not supported by pricing engine. ETA unknown.

`ContractItemPrice.ItemId` accepts a ProductCategory reference and the UI shows the field, but the `Contract_Pricing_Entries_Decision_Table` does not match on it. Salesforce Support confirmed November 2025: *"Category filter for Contract Pricing is not yet supported (future release)."* The Category Based Pricing & Discounting design doc (September 2026) explicitly lists pricing math as out of scope for the current iteration.

Customer demand confirmed: UKG, Wiley, Curvature, MongoDB, Datadog, UiPath, Progress.

**Workaround A — Product2 Enumeration (Phase 1)**
Create one CIP per product in the family. Supported today, data grows linearly with catalog size.

**Workaround B — LWC Auto-Generator (Low priority)**
LWC silently creates CIPs for all products in a selected category. Gives the UX illusion of category scope. Not recommended: stale on catalog change, CIP proliferation at scale, becomes technical debt when native support ships.

**Workaround C — Attribute Classification Proxy (Preferred long-term)**
Define a read-only classification attribute (e.g., `ProductFamily = "Licenses"`) on products. Use this attribute as the category discriminator in contract pricing logic:
- For **flat-rate family discounts**: use the native attribute PAS path with the classification attribute as the rule condition. Likely works today — needs live test to confirm whether a sentinel CIP is required to gate `IsContracted=true`.
- For **qty-based family tiers**: requires a custom procedure step / decision table taking (ContractId, ProductFamily attribute, AggregatedQuantity) as inputs. Compact tier grid — 3 rows per family regardless of catalog size. This is the right north-star design.

**Workaround D — Custom Decision Table Extension**
Add a new Expression Set step before the standard volume tier steps that:
1. Reads the line's classification attribute value
2. Looks up a contract-scoped rate card by (ContractId + ProductFamily + Quantity)
3. Applies the matching tier discount

Bypasses the ItemId matching limitation entirely.

---

### Gap 2 — Quote/Order.AggregationStrategy (PRD 262)
**Status:** In flight, not confirmed shipped.

PRD 262 adds `AggregationStrategy` to the Quote and Order headers, allowing cumulative pricing without a pricing contract. As of February 2026, whether the Quote field is in scope was still disputed; the work item names only `Order.AggregationStrategy`. A March 2026 PR mapped both fields in the SalesTransactionContext definition.

**Precedence order conflict:** Two PRD 262 sources disagree — one says Header → Contract → None; the other says Contract → Header → None. Confirm with owners before implementing.

New value: `CumulativeQuantityWithoutAsset` — aggregates current transaction quantity only, ignores existing assets.

**Today's constraint:** Cumulative pricing requires a Pricing Contract on the quote header. Set `Contract.AggregationStrategy = Cumulative`.

---

### Gap 3 — Scope Precedence (Product2 vs. ProductCategory)
No automatic specificity resolution when both a Product2-level CIP and a ProductCategory-level CIP exist on the same contract. `filterResultBy=OutputOrder`, `isBestFitEnabled=false` — first match in output order wins. For now: use separate contracts per scope level or avoid mixing scopes on one contract.

---

### Gap 3b — Bundle Child Lines: Out of Scope by Design (Confirmed 2026-10-26)
**Status:** Explicit use case exception. Not a defect. No fix planned.

The `Contract_Pricing_Entries_Decision_Table` has no concept of bundle parent/child context. CIP records match on `ItemId` (Product2), `ProductSellingModelId`, and date range only — there is no field to indicate "apply this CIP only when the product appears as a child of bundle X."

**Observed failure mode:** A bundle child added via the configurator has `DerivedStartDateTime__std = null`. With `doesConsiderNullValue = true` on the CIP DT, a null start date matches ALL CIP date ranges for that product simultaneously. If the product has multiple CIP records (e.g., Year 1 and Year 2), the DT returns multiple rows → "duplicate entries found" pricing failure.

**Fix in place (CHANGE 12):** The CIP list price filter requires `DerivedStartDateTime__std IS NOT NULL`. Bundle children with no start date skip the CIP DT and fall through to standard pricebook pricing.

**Design boundary:** Contract pricing applies to standalone lines only. Bundle child lines use standard pricebook pricing + bundle-based adjustments. This is the supported behavior for the 264 QuantumBit orgs.

---

### Gap 4 — `IsContracted` Never Set by Standard Procedure (Confirmed 264 org, 2026-10-13)
**Status:** Design flaw in `RLM_DefaultPricingProcedure`. Must be fixed manually per org.

**Symptom:** Contract pricing applies correctly to `UnitPrice` (CIP price matches), but the standard attribute-based pricing step still fires and overwrites `NetUnitPrice` with attribute pricing results.

**Root cause:** `Contract_Pricing_Entries_Decision_Table` outputs only `Price`, `DiscountType`, `DiscountValue` — it does NOT output the `IsContracted` context variable. The standard attribute pricing element has a gate condition `(IsContracted IS NULL OR IsContracted = false)`, which always passes because `IsContracted` is never written to `true`.

**Context Definition State (confirmed 264 org, 2026-10-13)**

`RLM_SalesTransactionContext` (Id: 11OWt000000IQLyMAO, version 10, active) already contains:

| Title | DataType | FieldType | IsTransient |
|---|---|---|---|
| `IsContracted` | boolean | inputoutput | true |
| `IsContracted__std` | boolean | inputoutput | true |
| `PricingContract` | lookup | inputoutput | false |
| `ContractPrice` | currency | output | true |
| `ContractDiscountType` | string | output | true |
| `ContractDiscountValue` | number | output | true |

`IsContracted` and `IsContracted__std` are **transient** — they exist only during the pricing run and are not hydrated from an sObject field. They are designed to be set by procedure logic. `PricingContract` is non-transient and IS hydrated from `Quote.PricingContractId` via context mapping — it is available to the procedure before any element runs.

**How the context works (plain language)**

The Sales Transaction Context is the in-memory data structure built from the quote before pricing runs. It holds working values as the procedure executes and writes results back to the quote and lines when finished.

- `PricingContract` holds the record ID of the pricing contract from `Quote.PricingContractId`. It is a string (ID), available before any procedure element runs.
- `IsContracted` is a boolean flag. It is transient — it only exists during the pricing run and is not read from or written back to any sObject field. It is designed to be set by procedure logic.
- Conditional logic in procedure elements uses: `PricingContract IS NOT NULL` / `PricingContract IS NULL` to check whether a contract is assigned, and `IsContracted = true` / `IsContracted IS NULL OR IsContracted = false` to gate whether contract pricing is active.

**Root cause (restated):** `PricingContract` is populated. `IsContracted` is in context. Nothing connects them. The attribute gate `(IsContracted IS NULL OR IsContracted = false)` always passes because `IsContracted` is never set.

**Fix — Assignment Step in Pricing Procedure**

Navigate to: Setup → Revenue → Pricing Procedures → `RLM_DefaultPricingProcedure`

1. Create a new **Constant** resource in the procedure:
   - Data type: Boolean
   - Value: `true`
   - Name: e.g. `ContractedTrue`

2. Locate the List Price element that has `IsContractEnabled = true` (the contract pricing path). Also locate the attribute-based adjustment section that follows — the standard attribute element has the gate `(IsContracted IS NULL OR IsContracted = false) AND ItemPricingSource Not Equals LastTransaction`.

3. Between the contract List Price element and the attribute section, add a **List Group element** container:
   - Condition: `ItemContractPrice IS NOT NULL`
   - **Ordering:** This container must sit *after* the contract List Price element so that `ItemContractPrice` is already populated when the condition evaluates. If it runs before, the value is still null and the flag never sets.
   - **Why `ItemContractPrice`, not `PricingContract`:** `PricingContract IS NOT NULL` is true for every line on a contracted quote, including lines with no CIP match. Those lines would skip attribute pricing and fall through with no adjustment price. `ItemContractPrice IS NOT NULL` limits the flag to lines that actually matched a CIP. A CIP with Price = 0 is not null and flags correctly.

4. Inside that List Group element, add an **Assignment** element:
   - **Input:** `ContractedTrue` (the Boolean constant)
   - **Output:** `IsContracted` (the context tag)
   - Note: the UI labels are counterintuitive — Input is the value being assigned FROM, Output is the context tag being written TO. Local variables cannot be used as the Output; only context tags are allowed there.

5. Confirm the standard attribute element's parent gate already includes `(IsContracted IS NULL OR IsContracted = false)` — no change needed there.

6. Save and activate the procedure.

**Result:** `NetUnitPrice` is correctly set to the CIP price. Attribute pricing is suppressed for contracted lines. However, the pricing waterfall still does not show "Derived from Contract" — see Known Issues below.

**Suspected Issue — "Derived from Contract" waterfall label missing**

Setting `IsContracted = true` via an external assignment fixes the attribute gate but likely does not produce the "Derived from Contract" waterfall label. That label comes from the List Price element's own internal output when `IsContractEnabled = true` and a CIP match is found — not from a context variable set elsewhere.

The procedure JSON confirms the List Price element has `IsContractEnabled = true` as a literal parameter. The element is finding the CIP ($8,999) but is not emitting `IsContracted = true` as an output or generating the waterfall trace. This is a **suspected platform defect** — not yet confirmed. No existing defect report has been found for this behavior.

A clean repro would show: CIP found ($8,999), `IsContractEnabled = true`, no `IsContracted` output, no "Derived from Contract" waterfall label.

**Waterfall mutual-exclusion consideration**

The procedure contains two List Price elements: one standard (`IsContractEnabled = false`) and one contract (`IsContractEnabled = true`). Revenue Cloud renders one List Price entry per line in the pricing waterfall. If the gate between the two elements depends on `IsContracted` — and `IsContracted` is never set — the standard element fires and claims the List Price slot in the waterfall. Even if the contract element also runs and sets `ItemContractPrice`, that result is invisible in the waterfall because the List Price slot is already occupied.

The downstream contract assignment containers (`Setlistpriceforlineswithcontractpricing`, `Setinputunitpriceforlineswithcontractpricing`) use Assignment elements to overwrite `ListPrice` and `InputUnitPrice` from `ItemContractPrice`. Assignment elements do not generate waterfall entries. So the waterfall shows the standard list price, the contract override is silent, and "Derived from Contract" never appears.

The correct design: the two List Price elements must be in mutually exclusive conditional containers — standard fires when no contract is present, contract fires when one is. Only then does the contract element produce the "Derived from Contract" waterfall entry as the List Price step. The entire failure chain — missing waterfall label, silent contract override — cascades from `IsContracted` never being set, which prevents that mutual exclusion from working.

This needs to be verified against the actual procedure element sequence before any further changes are made to the procedure.

**Proving the fix with the ExpressionSet simulation runtime**

The `revenue-pricing-simulation-run` skill (sf-skills-internal) provides a read-only simulation path that can prove the contract pricing waterfall without saving any records (`shouldSaveSimulationInput=false`). To test the Gap 4 fix:

1. Run `PATCH /services/data/v67.0/connect/omnistudio/evaluation-services/version-definitions/{urlId}/simulation` with `PricingContract = <contractId>` passed as a context tag in the simulation body.
2. The response's `additionalOutputData.pricingWaterfall[]` will show whether the contract List Price element fired and whether `Setattributebasedpricingforlineswithoutcontractpricing` was suppressed.
3. A line where `NetUnitPrice` equals the CIP price (not list price) and the attribute step is absent from the waterfall confirms the fix is working.

Note: the `revenue-pricing-simulation-run` skill explicitly lists `ContractId` as one of 56 supported context tags. The simulation requires a current (non-stale) DT refresh before it reflects any CIP changes. A `ContractId` context tag without a refreshed DT still prices from stale tables.

**Checks before filing a defect:**

1. Re-price a **new quote** after the fix — the old quote's saved waterfall will not update.
2. Inspect the conditional containers for both List Price elements — confirm whether their gates use `IsContracted` or a different condition, and whether they are truly mutually exclusive.
3. Check the List Price element's output mapping — verify whether `IsContracted` is mapped to a procedure output variable at all. If the mapping exists but the value is not written, that strengthens the case.
4. Confirm the same quote in a second org or an earlier patch level. Without this, you cannot separate a 264.8.101 regression from a setup issue in a fresh demo org.

---

## Phase 1 Build Plan

Prove the volume tier pattern end-to-end in the 264 org.

1. **Verify `Contract.AggregationStrategy` FLS** — confirmed accessible at release 264.8.101; add to Contract page layout
2. **Update Contract 00000102**
   - `IsPricingContract = true`
   - `AggregationStrategy = Cumulative`
3. **Create ContractItemPrice** for each target Licenses product (QB Enterprise, QB Business Critical, QB Starter)
   - `ContractId = 00000102`
   - `AdjustmentMethod = Slab`
   - `DiscountType = AdjustmentPercentage`
4. **Create 3 ContractItemPriceAdjTier records** per CIP
   - Tier 1: LowerBound=1000, UpperBound=4999, TierValue=10
   - Tier 2: LowerBound=5000, UpperBound=9999, TierValue=20
   - Tier 3: LowerBound=10000, UpperBound=null, TierValue=25
5. **Set `Quote.PricingContractId = 00000102`** on a test quote with Licenses products
6. **Reprice and verify** — check `PricingProcessExecution` records for `Contract_Pricing_Adjustment_Tiers` step firing and correct tier selection

## Phase 2 Build Plan

Attribute override pattern + classification proxy investigation.

1. Live-test sentinel CIP approach for attribute PAS path (does `IsContracted=true` require a Product2 CIP match or can the PAS lookup fire independently?)
2. Create contract-scoped PAS with bronze/silver/gold attribute rules for Pattern 2
3. Prototype custom decision table for qty-based family tiers using classification attribute (Workaround C/D)

---

## Validation Test Scenarios

Test matrix covering the full transaction lifecycle. Each scenario must be verified end-to-end: correct `InputUnitPrice`, correct waterfall display, correct `NetUnitPrice`, and no stale values from prior pricing runs.

### Group 1 — No Pricing Contract

| # | Scenario | Setup | Expected result |
|---|---|---|---|
| 1.1 | Net new quote, no contract | `Quote.PricingContractId = null`, new quote, no prior pricing | Standard list price in waterfall; `InputUnitPrice = ListPrice`; attribute/volume adjustments apply normally |
| 1.2 | Amend existing asset, no contract | `ItemPricingSource = LastTransaction`, `Quote.PricingContractId = null` | `InputUnitPrice` hydrated from Asset (last transaction price); standard adjustments apply on top; asset price NOT overwritten by list price reset |
| 1.3 | Renewal, no contract | Same as 1.2 with renewal transaction type | Same as 1.2 |

**Key risk for 1.2 and 1.3:** The current `OR (PricingContract IS NULL)` condition in the InputUnitPrice filter may overwrite the asset-hydrated price with `ListPrice`. Verify condition 2 (`ItemPricingSource Not Equals LastTransaction`) still protects amendment/renewal lines, or add `AND ItemPricingSource Not Equals LastTransaction` to the OR branch.

---

### Group 2 — With Pricing Contract

| # | Scenario | Setup | Expected result |
|---|---|---|---|
| 2.1 | Net new quote, contract set, CIP match | `Quote.PricingContractId` set, product has matching CIP | "Derived from Contract" in waterfall; `InputUnitPrice = CIP price`; attribute pricing suppressed |
| 2.2 | Net new quote, contract set, no CIP match for line | `Quote.PricingContractId` set, product has NO matching CIP | Standard list price in waterfall; attribute/volume adjustments apply; no stale CIP values |
| 2.3 | Amend existing asset, contract set, CIP match | `ItemPricingSource = LastTransaction`, contract set, CIP exists | Contract price wins over asset price; "Derived from Contract" in waterfall |
| 2.4 | Renewal, contract set, CIP match | Same as 2.3 with renewal type | Same as 2.3 — contract price takes precedence |

---

### Group 3 — Contract Change on Existing Transaction

| # | Scenario | Setup | Expected result |
|---|---|---|---|
| 3.1 | Switch from Contract A to Contract B — CIP exists on B | Reprice with `PricingContractId` updated to Contract B; Contract B has CIP for the line | `InputUnitPrice` resets to Contract B's CIP price; no stale price from Contract A |
| 3.2 | Switch from Contract A to Contract B — no CIP on B | Reprice with `PricingContractId` updated to Contract B; Contract B has NO CIP for this product | `ItemContractPrice` will be null (no DT match); downstream CIP assignment does not fire; `InputUnitPrice` retains Contract A's stale price unless procedure explicitly resets it |
| 3.3 | Remove pricing contract (policy edge case) | `Quote.PricingContractId` cleared on a previously contracted quote | Treated as Group 1 scenarios; standard path must reset `InputUnitPrice`; **business policy: this transition should be blocked at the UI/flow layer** — do not design the pricing procedure to rely on handling this gracefully |

**Gap for 2.2 and 3.2 — fixed:** See "If No Contract Pricing for Item — List Group Element Fix" section below. The fix covers both the no-CIP-match case (2.2) and the contract swap no-CIP case (3.2) by expanding the existing Standard List Price container to also fire for lines that have a contract but no CIP match.

**Design principle:** Removing a pricing contract from a live transaction is a business policy decision that should be prevented at the UI/orchestration layer (flow validation, page layout rules), not accommodated in the pricing procedure. The pricing procedure is not the right place to handle contract removal gracefully.

---

## Pricing Procedure Architecture Decision

### Context
The contract pricing logic requires modifications to the default pricing procedure (`RLM_DefaultPricingProcedure`). Two structural approaches exist for how to package those changes.

### Option A — Modified Default Procedure (current PoC approach)
Mutual exclusion of List Price elements via `PricingContract IS NOT NULL / IS NULL` gates, plus conditional logic for `IsContracted`, `InputUnitPrice` reset, and scenario 3.2 fix — all inside the default procedure.

- **Pro:** Single artifact, no additional enablement, works today, conditional logic proven in 264 org
- **Con:** Default procedure grows in complexity; Salesforce-shipped upgrades can conflict; contract and non-contract paths are entangled; harder to version contract pricing independently

### Option B — Separate Contract Procedure + Procedure Plan (target architecture)
Create a dedicated `QB_ContractPricingProcedure`. Wire a `ProcedurePlanDefinition` to route: `PricingContract IS NOT NULL` → contract procedure; else → default procedure. Default procedure stays ship-clean.

- **Pro:** Clean separation of concerns; contract procedure is a standalone deployable artifact; each procedure has no awareness of the other path; natural SE enablement story ("add the contract plan on top")
- **Con:** Requires more metadata (plan + 2 procedures); slightly more complex initial setup; routing condition must be kept in sync with business rules

### Option C — Manual SE Switching
Change the org-level `set-qocal-pricing-procedure` setting to toggle between procedures.

- **Not viable at quote level.** The setting is org-wide — flipping it affects all quotes in the org simultaneously. Only usable as an isolated demo toggle, not a real routing pattern.

### Org Confirmation (2026-10-14)
**Procedure Plan Orchestration for Pricing: Enabled** (confirmed in 264 org via Setup → Feature Settings → Revenue Cloud → Revenue Settings).

Two relevant settings:
| Setting | State | Notes |
|---|---|---|
| Procedure Plan Orchestration for Pricing | **Enabled** | Unlocks `ProcedurePlanDefinition` routing. Option B is available today — no enablement work needed. |
| Exclude Default and Sales Transaction Type Pricing Procedures | **Disabled** | When disabled, the org-level default procedure can still fire alongside the plan. Must be evaluated carefully when wiring the plan to avoid double-pricing. Enabling this makes the plan the sole routing authority. |

### Decision
**Two-phase approach:**

1. **Validate with Option A** — finish proving the contract logic (including scenario 3.2 fix) in the modified default procedure. This is the current state.
2. **Extract to Option B** — once logic is validated, move contract-specific elements into a dedicated `QB_ContractPricingProcedure` and wire the procedure plan. The contract procedure knows it always has a contract — no `PricingContract IS NULL` gates, no stale-price reset path needed. Scenario 3.2 fix simplifies: the routing condition (`PricingContract IS NOT NULL AND valid CIP exists`) is the gate.

The plan routing condition for Option B: `PricingContract IS NOT NULL`. Consider also whether to gate on `IsPricingContract = true` on the referenced contract to prevent routing to the contract procedure when a non-pricing contract is set.

---

## Platform Constraints & FLS Requirements

### Fields Requiring FLS / Profile Access
The following fields are restricted by default and must be explicitly granted to the relevant profile or permission set before they can be read or written via API or UI.

| Field | Object | Issue | Resolution |
|---|---|---|---|
| `IsPricingContract` | Contract | **System-set, never user-set.** Read-only FLS is correct by design — the field cannot be written via UI, API, or DML by any user. It flips to `true` automatically when the first ContractItemPrice (or other contract pricing record) is inserted against the contract. Source: Nicole Quilliam (Product), May 2025. | Add to Contract page layout for visibility only. To get `IsPricingContract=true`, insert a ContractItemPrice — the flag sets on CIP insert (exact timing: on insert vs. async refresh unconfirmed). |
| `AggregationStrategy` | Contract | FLS-restricted on some orgs; confirmed accessible at 264.8.101 | Verify field-level security; add to Contract page layout |
| `PricingContractId` | Quote | **FLS-restricted by default. Not on default page layouts.** This is NOT the same as `Quote.ContractId` (CRM contract relationship). `PricingContractId` is the field that activates the contract pricing path in the pricing procedure — without it set, the procedure never enters the `Contract_Pricing_Entries_Decision_Table` branch. Confirmed FLS issue in 264 org (2026-10-13). | Grant Read + Edit FLS to all relevant profiles. Add to Quote page layout. Also required for any Flow/trigger setting this field — the running user's profile must have Edit FLS or the write silently fails. |
| `PricingContractId` | QuoteLineItem | **FLS confirmed available in 264 org (2026-10-14). Field is on the page layout, not read-only.** The field is NOT populated by FLS alone — the pricing procedure must explicitly propagate the value via an Assignment element. Without this element, `QuoteLineItem.PricingContractId` stays null regardless of FLS state. See `QuoteLineItem.PricingContractId` Line Propagation section below. | Add unconditional Assignment element to procedure (see below). FLS and page layout already correct in 264 org. |
| `SellingModelType` | ContractItemPrice | UI auto-defaults to "One Time" when a Product/Category is selected and does NOT update when ProductSellingModelId is changed. Causes mismatch validation errors in the UI. | Create ContractItemPrice records via API/CLI. Set `SellingModelType = null` and `ProductSellingModelId = null` to match all selling models (DT has `doesConsiderNullValue=true` on both fields). |

### `QuoteLineItem.PricingContractId` Line Propagation — Context Definition Finding and Fix

**Context definition dual-mapping (confirmed 264 org, 2026-10-14, via metadata retrieve of `RLM_SalesTransactionContext`)**

`PricingContract` context variable exists at two distinct levels:

| Level | Context Node | Source sObject Field | Builder Variable Name |
|---|---|---|---|
| Header | `SalesTransaction` | `Quote.PricingContractId` | `PricingContract` |
| Line | `SalesTransactionItem` | `QuoteLineItem.PricingContractId` | `ItemPricingContract` |

Both are `FieldType = inputoutput`, non-transient. The platform reads them as inputs at run start and writes them back as outputs at run end.

**Why the field was not being populated (despite FLS being open):**
The context definition reads `QuoteLineItem.PricingContractId` INTO `ItemPricingContract` as an input at run start. For the platform to write back, the procedure must change the value during the run. If no procedure element assigns a value to `ItemPricingContract`, the platform writes back whatever was read in — null for new lines, or a stale value for repriced lines. The procedure had no such element.

**Stale value risk:**
If `QuoteLineItem.PricingContractId` held a prior contract's ID (Contract A), repricing with a new header contract (Contract B) would hydrate line-level `ItemPricingContract = Contract A` before the procedure runs. Any procedure logic or DT input resolving against the line-level variable would see Contract A, not Contract B — pricing against the wrong contract even though the header was updated.

**Fix — Unconditional Assignment element (confirmed working 2026-10-14):**
Add an Assignment element early in the procedure (before the contract List Price containers), outside any Conditional List:
- **Input:** `PricingContract` (SalesTransaction node — header value)
- **Output:** `ItemPricingContract` (SalesTransactionItem node — line value)
- **No gate condition** — runs unconditionally for every line on every reprice

Result: `QuoteLineItem.PricingContractId` is always in sync with `Quote.PricingContractId` after every pricing run.
- **Header null → all lines written null** — stale contract IDs cleared automatically
- **Header = Contract ID → all lines written that ID** — even lines with no CIP match
- **Contract swap** — new contract ID overwrites old ID on all lines before any DT runs

Confirmed working across all three cases in 264 org.

**Map Line Item element — not viable here:**
Map Line Item must be in position 2 in the procedure. Position 2 is already occupied by the existing item detail Map Line Item (`SalesTransactionItem → SalesTransactionItemDetail`). These use different source/target node pairs and cannot be merged into one element. Assignment achieves the same result.

**Semantic note:** With this fix, `QuoteLineItem.PricingContractId` reflects "which pricing contract was in scope for this quote" for all lines, not "which contract produced a CIP match for this line." This is more useful for downstream tracing — it tells you the pricing context regardless of whether a specific CIP fired.

---

### "If No Contract Pricing for Item" — List Group Element Fix (Scenarios 2.2 and 3.2)

**Problem:** When `Quote.PricingContractId` is set but a specific line has no matching CIP, the line is inside the `PricingContract IS NOT NULL` container. The Contract List Price element finds no CIP match, `ItemPricingContract` remains null, and the Standard List Price element is gated on `PricingContract IS NULL` — so it never fires. The line gets no standard list price waterfall entry and retains whatever `InputUnitPrice` was previously set (stale from prior contract or from the initial assignment).

**Applies to:**
- Scenario 2.2: Contract set on quote, product has no CIP → Standard list price should fire, attribute/volume adjustments apply normally
- Scenario 3.2: Contract swap (A → B), new contract has no CIP for a product → stale Contract A price must be reset to standard list price before CIP assignments run

**Fix — Modify the existing Standard List Price List Group element:**

The procedure has a List Group element previously named "If NOT Pricing Contract," containing the Standard List Price element, gated on `PricingContract IS NULL`. Rename it and expand its condition logic:

- **Rename to:** "If No Contract Pricing for Item"
- **Add condition 2:** `PricingContract IS NOT NULL`
- **Add condition 3:** `ItemPricingContract IS NULL`
- **Change filter logic to custom:** `1 OR (2 AND 3)`

| # | Condition | Meaning |
|---|---|---|
| 1 | `PricingContract IS NULL` | No contract on the quote at all |
| 2 | `PricingContract IS NOT NULL` | Contract is set on the quote |
| 3 | `ItemPricingContract IS NULL` | Contract is set but no CIP matched for this line |

`1 OR (2 AND 3)` = Standard List Price element fires when: no contract on quote, OR contract on quote but no CIP match for this line.

**Why this is better than a separate reset Assignment element:**
- The Standard List Price element fires and correctly sets both `ListPrice` and `InputUnitPrice` through its own logic — not a silent variable overwrite
- The pricing waterfall gets a proper List Price entry for these lines (not a gap)
- No additional element required — reuses the existing Standard List Price element for both cases

**Critical ordering requirement:** This List Group element must be positioned **after** the Contract List Price element container in the procedure sequence. `ItemPricingContract` must already be evaluated (null or populated) when condition 3 fires. If the Standard List Price container runs before the Contract List Price container, `ItemPricingContract` is still null for all lines and condition 3 always fires — breaking contracted lines.

**Variable name confirmation:**
- `PricingContract` = `Quote.PricingContractId` (header-level context variable, SalesTransaction node)
- `ItemPricingContract` = the contract price result for the line (SalesTransactionItem node) — NOT the line-level contract ID. This is the output of the Contract List Price element. Null when no CIP matched; populated when a CIP match was found.

---

### `PriceAdjustmentTier.EffectiveFrom` — Required, Not Nillable in Practice
The field describe shows `nillable: true`, but the org enforces both rules at insert (confirmed live — each produced a real `400`):

1. **`EffectiveFrom` is required.** Omitting it returns `400 INVALID_INPUT`: *"Specify the Effective From date to save your price adjustment tier."*
2. **Must fall inside the parent schedule's date range.** A value earlier than the schedule's own `EffectiveFrom` returns `400 FIELD_INTEGRITY_EXCEPTION`: *"Change the effective date range of price adjustment tier within the date range of price adjustment schedule."* Do not use midnight or a naive "today." **Safest: stamp each tier with the schedule's exact `EffectiveFrom` value.**

Applies to both `PriceAdjustmentTier` (pattern 1 volume tiers) and `ContractItemPriceAdjTier` (contract pricing tiers) — apply the same rule to both.

### `PriceAdjustmentSchedule.IsActive` Does NOT Gate Tier Application
The `IsActive` flag on a `PriceAdjustmentSchedule` does **not** control whether its tiers are applied at pricing time — neither at decision-table materialization nor at runtime. Proven in-org with a 3-run simulation (active, inactive same materialization, inactive with fresh DT sync) — all three returned the full tier ladder identically.

Implications:
- Do not filter or rank schedules by `IsActive` when resolving which to use.
- An inactive schedule still prices correctly. Do not activate a schedule as a troubleshooting step for "tiers not applying."
- If tiers aren't applying, the cause is either a stale DT (needs refresh) or a procedure wiring miss (the volume step's `VolumePASIdConstant` constant points at a different schedule than the one tiers are on).

### `set-contract-price-flow` Org Setting — Unverified in 264 Org
The `revenue-settings-configure` skill lists a `set-contract-price-flow` operation: `PATCH /headless/invoke/platform/revenue-settings/set-contract-price-flow`. This is a Revenue org-level setting for the contract pricing flow. It has not been checked in the 264 org.

**Action item:** Read the current value via `GET /headless/invoke/platform/revenue-settings/get-initial-org-values` and confirm whether a contract price flow is configured. If not set, this may be a required step for the contract pricing path to function end-to-end.

### Contract Lifecycle Constraint — PAS Must Be Linked Before Activation
`PriceAdjustmentSchedule.ContractId` is validated against the contract's status. Assigning a PAS to an **Activated** contract throws:
> *"You can't assign price adjustment schedules to an active contract. Select a new contract and try again."*

**Required setup sequence:**
```
1. Create Contract → status = Draft
2. Set AggregationStrategy = Cumulative (if using cumulative qty) — writable via API on Draft
3. Create PriceAdjustmentSchedule with ContractId set — MUST be while Draft (blocked on Activated)
4. Create ContractItemPrice records — supported on Draft (recommended approach per product guidance)
        → Activation validates CIP end dates are on or before the contract's end date
5. Activate the Contract
        → IsPricingContract flips to true automatically on first CIP insert (confirmed live)
6. Create ContractItemPriceAdjTier records linked to each CIP
7. Set Quote.PricingContractId manually → pricing is now live
```

**PAS requires Draft; CIPs work on both Draft and Activated:**
- `PriceAdjustmentSchedule.ContractId`: only writable when contract is **Draft**
- `ContractItemPrice`: Can be created on **Draft** contracts — confirmed working in this org. Critical constraint: CIP `StartDate` must be on or after the contract's own `StartDate` (platform validation). Prior UNKNOWN_EXCEPTION failures were caused by a missing/mismatched contract StartDate, not by Draft status. Recommendation: create CIPs on Draft before activation so they can still be updated.

**Activated contract restrictions (source: Gita Sreekumar, Product, Oct 2026):**
- There are validations restricting updates to activated contracts — no documented path from Activated → Draft in Revenue Cloud
- Account field on an activated contract cannot be edited (even by system admin); workaround is delete and recreate
- To update contract pricing: use amendments (picks up updated contract prices after decision tables refresh) or clone to a new Draft contract
- Status picklist is configurable — check whether your org allows Activated → Draft transition

**IsPricingContract is system-set:** Read-only by design for all users, all profiles, all API contexts. Flips to `true` automatically when the first ContractItemPrice is inserted against an Activated contract. Confirmed live. Do not attempt to write it.

**Quote.PricingContractId is NOT auto-populated:** Must be set explicitly on the quote. The platform roadmap includes "Contract Determination / Resolution" to auto-fetch the right pricing contract for a transaction, but no ship date confirmed. Current approach: set the field manually or via a flow/trigger on quote creation.

---

## ARC Transaction — Contract and Pricing Contract Alignment

### The Gap

When Revenue Cloud creates an amendment, renewal, or other ARC transaction, it creates a new quote. `Quote.ContractId` (the CRM contract relationship) IS carried forward — the amendment quote is linked back to the originating contract. **`Quote.PricingContractId` is NOT carried forward — it is null on every ARC transaction quote.**

This means: without automation, all amendment and renewal quotes enter the pricing procedure with `PricingContract IS NULL`. Contract pricing never fires. All lines fall through to Group 1 behavior regardless of what the original quote was priced against.

The 4-condition List Group element logic designed for amendment/renewal lines only applies once `Quote.PricingContractId` is populated. Until it is, every ARC line hits `PricingContract IS NULL` and the Standard List Price element fires — overwriting the asset-hydrated price unless the `ItemPricingSource Not Equals LastTransaction` guard (condition 4) is in place.

### Real-World vs. Demo Distinction

In production deployments, `Quote.ContractId` (CRM contract — governs legal terms, obligations, account relationship) and `Quote.PricingContractId` (pricing contract — governs CIPs, tiers, discount rules) may reference **different records**. A customer may have one master services agreement and multiple pricing contracts scoped by product line, region, or fiscal year. The pricing contract the ARC quote should use is not always derivable from the CRM contract alone — it requires contract determination logic.

For the QuantumBit 264 demo, these are the **same record**. `Quote.ContractId = Quote.PricingContractId`. This simplifies the demo story: one contract governs both terms and pricing.

### Required Platform Automation (Deferred)

**Status: Not yet built. Documented here as a required design item before ARC scenarios can be demonstrated.**

A flow (or Apex trigger) must fire on ARC transaction quote creation and populate `Quote.PricingContractId`. Two options:

**Option 1 — Direct copy from `Quote.ContractId` (demo approach)**
When `ContractId = PricingContractId` by design, simply copy the field:
```
Trigger: Quote created via ARC transaction
Condition: Quote.ContractId IS NOT NULL AND Quote.PricingContractId IS NULL
Action: Quote.PricingContractId = Quote.ContractId
```
Simple. Works for the 264 demo. Not suitable for orgs where the two fields diverge.

**Option 2 — Contract determination lookup (enterprise approach)**
Query for the active pricing contract scoped to the account (or account + product category) and assign it. This is the pattern the platform roadmap "Contract Determination / Resolution" feature will eventually automate. For now, a custom flow with a lookup table or formula is required.

### Impact on Procedure Logic

| Without automation | With automation |
|---|---|
| All ARC quotes: `PricingContract IS NULL` | ARC quotes: `PricingContractId` populated from `ContractId` |
| All ARC lines → Standard List Price path | ARC lines with CIP → contract path; without CIP → asset holds |
| Group 2/3 scenarios cannot be demonstrated on amendments/renewals | Full matrix (Groups 1–3) works end-to-end |
| `ItemPricingSource Not Equals LastTransaction` guard (condition 4) is redundant | Condition 4 is essential — without it, Standard List Price overwrites asset prices on no-CIP amendment lines |

### Relationship to Validation Test Scenarios

Scenarios 2.3, 2.4, and 3.1–3.3 in the test matrix require `Quote.PricingContractId` to be set on ARC transaction quotes. Until the automation is in place, those scenarios must be triggered by manually setting `Quote.PricingContractId` on the amendment/renewal quote. Add this as a prerequisite step in each ARC test scenario execution.

---

## sf CLI Quick Reference

All sf commands via PowerShell:
```powershell
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' [args]"
```

Tooling API (PricingRecipe, DecisionTable, ExpressionSetDefinition):
```powershell
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' data query --query '...' --use-tooling-api --target-org 264org"
```

Single quotes in WHERE clauses — use `[char]39`:
```powershell
--query ('SELECT Id FROM Contract WHERE ContractNumber = ' + [char]39 + '00000102' + [char]39)
```
