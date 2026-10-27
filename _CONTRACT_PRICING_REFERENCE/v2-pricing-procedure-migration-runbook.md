# Agent Runbook: Contract Pricing Migration — V1 to V2
## RLM Revenue Management Default Pricing Procedure

**Target org:** Any org running `RLM Revenue Management Default Pricing Procedure` (version 1, rank 1, active)
**Reference org:** new-264-org (trailsignup-d70659642059f4.my.salesforce.com) — V2 is the authoritative target state
**API version:** 68.0 (Release 264+)

---

## Prerequisites

Before touching the pricing procedure, complete the following metadata changes in order.

---

## SECTION 1 — Quote Record: PricingContractId Field

### 1A — Field Level Security

`Quote.PricingContractId` was introduced in Release 264 (API v68.0). It must be visible to all profiles before it can be set by the flow or read by the pricing procedure.

1. Navigate to **Setup → Object Manager → Quote → Fields & Relationships → PricingContractId**
2. Click **Set Field-Level Security**
3. Check **Visible** for every profile listed
4. Uncheck **Read-Only** where it is checked (needs to be editable)
5. Click **Save**

### 1B — Add to Page Layouts

1. Navigate to **Setup → Object Manager → Quote → Page Layouts**
2. For each page layout in the org:
   - Open the layout
   - Find the `ContractId` field (already on the layout)
   - Drag `Pricing Contract ID` (`PricingContractId`) onto the layout immediately below `ContractId`
   - Save

### 1C — Add to Lightning Record Page

1. Navigate to **Setup → Lightning App Builder**
2. Find and open the record page named **RLM_Quote_Record_Page**
3. Click the **Details** tab component
4. Locate the `Contract` field in the Fields section
5. Drag **Pricing Contract ID** below the `Contract` field
6. Click **Save**
7. If prompted to activate, confirm activation

---

## SECTION 2 — Quote Line Item Record: PricingContractId Field

### 2A — Field Level Security

`QuoteLineItem.PricingContractId` was also introduced in Release 264. Same procedure as Section 1A but on the Quote Line Item object.

1. Navigate to **Setup → Object Manager → Quote Line Item → Fields & Relationships → PricingContractId**
2. Click **Set Field-Level Security**
3. Check **Visible** for every profile listed
4. Uncheck **Read-Only** where checked
5. Click **Save**

### 2B — Add to Page Layouts

1. Navigate to **Setup → Object Manager → Quote Line Item → Page Layouts**
2. For each page layout:
   - Open the layout
   - Drag `Pricing Contract ID` onto the layout (place it near other pricing-related fields)
   - Save

---

## SECTION 3 — New Flow: RLM Set Pricing Contract On Quote

This Before Save flow keeps `Quote.PricingContractId` in sync with `Quote.ContractId` at all times. Without it, direct-contract quotes (where ContractId is set manually rather than via ARC amendment) will have `PricingContractId = null` and the pricing procedure Assignment element in CHANGE 1 will have nothing to copy down to lines.

### 3A — Prerequisites

**Verify FLS is complete first (Sections 1A and 2A must be done).**

Check for conflicting flows:

```bash
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' data query \
  --query 'SELECT ApiName, Label, TriggerOrder FROM FlowDefinitionView WHERE TriggerType = ''RecordBeforeSave'' AND IsActive = true AND TriggerObjectOrEvent.QualifiedApiName = ''Quote''' \
  --target-org <alias> --json"
```

If any existing Before Save flow on Quote already assigns `PricingContractId`, **stop and review** before proceeding. Do not deploy a second flow that sets the same field.

### 3B — Deploy via Metadata

Write the following file to disk:

**Path:** `<project-root>/force-app/main/default/flows/RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Flow xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>68.0</apiVersion>
    <description>Keeps Quote.PricingContractId in sync with Quote.ContractId. Fires before every quote save and assigns PricingContractId = ContractId when the two fields differ (including when ContractId is cleared to null).</description>
    <environments>Default</environments>
    <interviewLabel>RLM Set Pricing Contract On Quote {!$Flow.CurrentDateTime}</interviewLabel>
    <label>RLM Set Pricing Contract On Quote</label>
    <processType>AutoLaunchedFlow</processType>
    <start>
        <locationX>50</locationX>
        <locationY>0</locationY>
        <connector>
            <targetReference>Assign_PricingContractId</targetReference>
        </connector>
        <filterFormula>OR(
  AND(ISNULL({!$Record.ContractId}), NOT(ISNULL({!$Record.PricingContractId}))),
  AND(NOT(ISNULL({!$Record.ContractId})), {!$Record.ContractId} &lt;&gt; {!$Record.PricingContractId})
)</filterFormula>
        <object>Quote</object>
        <recordTriggerType>CreateAndUpdate</recordTriggerType>
        <triggerType>RecordBeforeSave</triggerType>
    </start>
    <assignments>
        <name>Assign_PricingContractId</name>
        <label>Assign PricingContractId</label>
        <locationX>50</locationX>
        <locationY>140</locationY>
        <assignmentItems>
            <assignToReference>$Record.PricingContractId</assignToReference>
            <operator>Assign</operator>
            <value>
                <elementReference>$Record.ContractId</elementReference>
            </value>
        </assignmentItems>
    </assignments>
    <status>Active</status>
</Flow>
```

Deploy — **confirm target org alias before running**:

```bash
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' project deploy start \
  --source-dir force-app/main/default/flows/RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml \
  --target-org <alias> --json"
```

**Expected result:** `"status": "Succeeded"`, `RLM_Set_Pricing_Contract_On_Quote` listed in `files[]` with `"state": "Created"`.

### 3C — Verify

```bash
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' data query \
  --query 'SELECT ApiName, Label, TriggerType, RecordTriggerType, IsActive FROM FlowDefinitionView WHERE ApiName = ''RLM_Set_Pricing_Contract_On_Quote''' \
  --target-org <alias> --json"
```

Expected: `IsActive: true`, `TriggerType: RecordBeforeSave`, `RecordTriggerType: CreateAndUpdate`

### 3D — Behavior reference

| ContractId | PricingContractId (before save) | Flow fires? | PricingContractId (after save) |
|---|---|---|---|
| null | null | No | null (unchanged) |
| 800Wt... | null | Yes | 800Wt... (set) |
| 800Wt... | 800Wt... (same) | No | 800Wt... (unchanged) |
| 800Wt...B | 800Wt...A (different) | Yes | 800Wt...B (updated) |
| null | 800Wt... (cleared) | Yes | null (cleared) |

---

## SECTION 4 — Pricing Procedure Changes

Work in the **Revenue Cloud Price Management** application. Navigate to **Revenue Cloud → Price Management → Pricing Procedures → RLM Revenue Management Default Pricing Procedure**.

### Preliminary: Create Version 2

1. Open the pricing procedure. If V1 is active, deactivate it first:
   - Open V1 → click **Deactivate** → confirm
2. From the procedure, click **Save As** (or **New Version**)
3. Set the following fields:
   - **Version Name:** `RLM Revenue Management Default Pricing Procedure v2`
   - **Version Number:** `2`
   - **Rank:** `2`
4. Click **Save**
5. Open the newly created V2 version. It starts as Inactive. Make all CHANGE 1–8 edits on this version before activating.

---

### CHANGE 1 — Add Assignment Element: Pass Pricing Contract ID from Quote to Quote Lines

**What and why:** The line-level `PricingContractId` field on QuoteLineItem is not automatically populated from the quote header. The pricing procedure must explicitly copy it. This Assignment element runs at the very beginning (seq 3) so every downstream contract element gets a non-null `ItemPricingContract` context variable before any DT lookup runs.

**Where to add it:** In the outer procedure sequence, after the element at position 2 (`Map Line Items` / `MapLineItemContextTagsToCommonPricingVariables`) and before the element at position 4 (`Assign Effective From Date to Pricing Date`). This element becomes seq 3.

**Steps:**
1. In the outer procedure sequence, click **Add Element** between position 2 and 4
2. Select element type: **Assignment**
3. Set **Name:** `Pass Pricing Contract ID from Quote to Quote Lines`
4. In the Assignment section:
   - **Input (source):** `PricingContract` — this is the header-level (SalesTransaction) context variable, mapped to `Quote.PricingContractId`
   - **Output (target):** `ItemPricingContract` — this is the line-level (SalesTransactionItem) context variable, mapped to `QuoteLineItem.PricingContractId`
5. Save the element

**Do not touch** the `Mapcontexttagstocommonpricingvariables` (Map Line Items) Pricing Settings element at position 1. It maps `Contract = ItemContract` — leave that alone. `ItemContract` is the platform-native variable for ARC amendment lines; changing it breaks amendment pricing.

**Verification (after all changes and activation):** Query `QuoteLineItem` for a quote that has `Quote.PricingContractId` set. After any reprice, all line items should show `PricingContractId` matching the header value.

---

### CHANGE 2 — Edit List Price Element: Assigned From Pricing Contract

**What and why:** The `Assigned From Pricing Contract` element is the List Price element with **Use contract-based pricing** checked, mapped to the `Contract Pricing Entries` decision table. Its `Contract` input was pointing to `ItemContract` (the ARC amendment variable, null for direct-contract quotes). Switching it to `ItemPricingContract` (set by CHANGE 1) makes the DT lookup work for direct-contract quotes.

**Where to find it:** Inside the conditional group **Set List Price for Lines With Contract Pricing** → the List Price element named `Assigned From Pricing Contract` (it has `Use contract-based pricing` checked, lookup name = `Contract Pricing Entries`).

**Steps:**
1. Open the conditional group **Set List Price for Lines With Contract Pricing**
2. Click the List Price element **Assigned From Pricing Contract**
3. Click **Edit**
4. Scroll to the **Input Rule Variables** section
5. Find the row where the DT input column is **Contract** (or `ContractId`)
6. Change the mapped variable from `ItemContract` → `ItemPricingContract`
7. Save

**Do not change** the `ContractId` row in the Pricing Settings BKM element (`Mapcontexttagstocommonpricingvariables`). That element also maps `Contract = ItemContract` — it must stay as `ItemContract`. Only the `Assigned From Pricing Contract` List Price element changes.

---

### CHANGE 3 — Fix Filter Element: Set List Price for Lines With Contract Pricing (Root Cause Fix)

**What and why:** The Filter element inside this conditional group has a circular dependency that permanently blocks all contract pricing from executing. The filter requires `IsContracted IS NOT NULL AND IsContracted EQUALS true`. But `IsContracted` starts as `null` at the beginning of every pricing run — it is only set to `true` by the `Assigned From Pricing Contract` DT element that lives inside this same container at seq 2. Because the filter runs first (seq 1), all lines are blocked before the DT fires. The DT never runs. `IsContracted` is never set. Every downstream contract container is also gated on `IsContracted = true` — so the entire contract pricing waterfall is permanently locked out for every pricing run.

The fix: replace the filter condition with a check on `ItemPricingContract`, which is already populated by CHANGE 1 before this container runs.

**Where to find it:** Inside the conditional group **Set List Price for Lines With Contract Pricing** → the first element, the Filter element named `Filter lines with contract pricing for which list price must be set` (seq 1 inside the container).

**Current broken state (V1 and current V2 as retrieved — to be replaced):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Item Pricing Source | Is Null | — |
| 2 | Is Contracted | Is Not Null | — |
| 3 | Is Contracted | Equals | true |

Logic: All Conditions Are Met (AND)

**Steps:**
1. Open the conditional group **Set List Price for Lines With Contract Pricing**
2. Click the Filter element **Filter lines with contract pricing for which list price must be set**
3. Click **Edit**
4. Delete all 3 existing conditions
5. Add a single new condition:
   - **Field:** `Item Pricing Contract`
   - **Operator:** `Is Not Null`
   - **Value:** (none)
6. Set filter logic: **All Conditions Are Met** (only 1 condition)
7. Save

**Result:** Lines where `ItemPricingContract` is not null (set by CHANGE 1) enter the container. The `Assigned From Pricing Contract` DT runs. If a CIP match is found, `ItemContractPrice` is returned and `IsContracted` is set to `true`. All downstream contract elements gated on `IsContracted = true` then unlock correctly for matched lines.

---

### CHANGE 4 — Edit Volume Discount Element: Discount Assigned From Pricing Contract — **CONFIRMED VERIFIED**

**What and why:** The contract Volume Discount element looks up volume tiers from the `Contract Pricing Volume Tiers` decision table using a `ContractId` input (the `Id` row). It was mapped to `ItemContract` — null for direct-contract quotes — so no volume tier matches were found. Switching to `ItemPricingContract` makes the lookup work.

**Where to find it:** Inside the conditional group **Apply Volume Based Discounts to Lines With Contract and Without Derived Pricing** → the Volume Discount element.

**Steps:**
1. Open the conditional group **Apply Volume Based Discounts to Lines With Contract and Without Derived Pricing**
2. Click the Volume Discount element (the one mapped to the contract volume tiers table)
3. Click **Edit**
4. In the **Input Rule Variables** section, find the row where the DT input is **Id** (the contract identifier column)
5. Change the mapped variable from `ItemContract` → `ItemPricingContract`
6. Save

**The filter element inside this container** (`Filter lines with derived pricing and without contract or last-trxn pricing`) already has correct conditions in V1 — it gates on `IsContracted IS NOT NULL AND IsContracted EQUALS true`. No changes needed to that filter.

---

### CHANGE 5 — Edit Contract Attribute Pricing Filter Element

**What and why:** The contract attribute pricing element at **Set Attribute Based Pricing for Lines Without Derived Pricing** handles lines that matched a CIP and have a contract-scoped PriceAdjustmentSchedule (`ItemContractAttributePasId`). In V1 this filter has 4 conditions but lacks `IsContracted` gating — meaning it could attempt attribute pricing for non-contracted lines. V2 adds 2 conditions to correctly limit this element to contracted lines only.

**Where to find it:** Inside the conditional group **Set Attribute Based Pricing for Lines Without Derived Pricing** → the Filter element named `Filter lines without derived or last-trxn pricing, and with price adj schedule` (seq 1).

**Current V1 state (4 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Item Contract Attribute PAS Id | Is Not Null | — |
| 2 | Item Pricing Source | Not Equal To | LastTransaction |
| 3 | Derived Pricing Attribute | Is Not Null | — |
| 4 | Derived Pricing Attribute | Equals | false |

Logic: All Conditions Are Met (AND)

**Target V2 state (6 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Item Contract Attribute PAS Id | Is Not Null | — |
| 2 | Item Pricing Source | Not Equal To | LastTransaction |
| 3 | Derived Pricing Attribute | Is Not Null | — |
| 4 | Derived Pricing Attribute | Equals | false |
| 5 | Is Contracted | Is Not Null | — |
| 6 | Is Contracted | Equals | true |

Logic: All Conditions Are Met (AND, all 6)

**Steps:**
1. Open the conditional group **Set Attribute Based Pricing for Lines Without Derived Pricing**
2. Click the Filter element **Filter lines without derived or last-trxn pricing, and with price adj schedule**
3. Click **Edit**
4. Verify conditions 1–4 are present as listed above
5. Add condition 5: **Is Contracted | Is Not Null**
6. Add condition 6: **Is Contracted | Equals | true**
7. Confirm logic is **All Conditions Are Met** (all 6 AND)
8. Save

---

### CHANGE 6 — Edit Fallback Filter Element: Set Input Unit Price for Lines Without Derived Pricing or Last Transaction Pricing

**What and why:** This container sets `InputUnitPrice` for standard (non-contracted, non-last-transaction) lines. Its filter in V1 has 4 conditions but lacks any `IsContracted` exclusion. After the contract pricing waterfall runs (and sets `IsContracted = true` for matched lines), contracted lines have already had `InputUnitPrice` set from the CIP. Without this fix, those lines could re-enter this container and have `InputUnitPrice` overwritten with pricebook list price.

**Where to find it:** Inside the conditional group **Set Input Unit Price for Lines Without Derived Pricing or Last Transaction Pricing** → the Filter element named `Filter lines without derived or last-transaction pricing, or an input unit price` (seq 1).

**Current V1 state (4 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Input Unit Price | Is Null | — |
| 2 | Item Pricing Source | Not Equal To | LastTransaction |
| 3 | Derived Pricing Attribute | Is Not Null | — |
| 4 | Derived Pricing Attribute | Equals | false |

Logic: All Conditions Are Met (AND)

**Target V2 state (5 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Input Unit Price | Is Null | — |
| 2 | Item Pricing Source | Not Equal To | LastTransaction |
| 3 | Derived Pricing Attribute | Is Not Null | — |
| 4 | Derived Pricing Attribute | Equals | false |
| 5 | Is Contracted | Equals | false |

Logic: All Conditions Are Met (AND, all 5)

**Steps:**
1. Open the conditional group **Set Input Unit Price for Lines Without Derived Pricing or Last Transaction Pricing**
2. Click the Filter element **Filter lines without derived or last-transaction pricing, or an input unit price**
3. Click **Edit**
4. Verify conditions 1–4 are present as listed above
5. Add condition 5: **Is Contracted | Equals | false**
6. Confirm logic is **All Conditions Are Met** (all 5 AND)
7. Save

**Note on condition 5 value:** `false` (boolean literal), not `null`. Lines where `IsContracted` is null also pass through this filter — condition 5 only excludes lines where `IsContracted = true` (confirmed contract-priced lines). Standard lines and amendment lines without a contract match both have `IsContracted = null` and correctly pass through to this container.

---

### CHANGE 7 — Edit List Price Element: Assigned From Pricing Contract — Per-Line Date Input for CIP DT Lookup

> ✅ **CONFIRMED** — Verified in new-264-org (2026-10-20). The pricing waterfall shows the correct per-line CIP price for each line: Year 1 line → CIP #2 ($8,999), Year 2 line → CIP #3 ($7,999). DT input parameters inside a List Price element resolve per-line.

**Background — what was tried and why it failed:**

The outer-sequence element `Assign the EffectiveFrom date to PricingDate` (seq 6) sets `PricingDate = EffectiveFrom`. Although the context definition declares `EffectiveFrom` as a tag alias on `SalesTransactionItem/StartDate` (line-level), empirical testing confirms it resolves to a single header-scope value at the outer-sequence level — every line shares the same `PricingDate` when the CIP DT fires, so all lines match the same CIP regardless of their individual `StartDate` values.

An Assignment element inside the container (setting `StartDate → PricingDate` immediately before the DT) was also tried and also failed. **Assignment elements resolve context variables at header (SalesTransaction) scope regardless of where they appear.** `StartDate` and `PricingDate` are both header-scoped in an Assignment element — the assignment just moves one header value into another.

**Why this approach should work:**

A **List Price element** is per-line by design in the RLM pricing engine — it executes once per `SalesTransactionItem`. DT input parameters inside a List Price element resolve at line (SalesTransactionItem) scope. `DerivedStartDateTime__std` is a platform-standard `SalesTransactionItem` context variable explicitly derived from `QuoteLineItem.StartDate` + `QuoteLineItem.StartTime`. Passing it directly as the StartDate and EndDate DT column inputs bypasses `PricingDate` entirely, giving each line's DT lookup its own effective date.

**Where to find it:** Inside the conditional group **Set List Price for Lines With Contract Pricing** → the List Price element `Assigned From Pricing Contract` (seq 2).

**Current state:**

| DT Input Column | Mapped Procedure Variable |
|---|---|
| StartDate | `PricingDate` |
| EndDate | `PricingDate` |

**Target state:**

| DT Input Column | Mapped Procedure Variable |
|---|---|
| StartDate | `DerivedStartDateTime__std` |
| EndDate | `DerivedStartDateTime__std` |

**Steps:**
1. Open the conditional group **Set List Price for Lines With Contract Pricing**
2. Click the **Assigned From Pricing Contract** List Price element → **Edit**
3. In the **Input Rule Variables** section, find the row where the DT input column is **StartDate**
4. Change the mapped variable from `PricingDate` → `DerivedStartDateTime__std`
5. Find the row where the DT input column is **EndDate**
6. Change the mapped variable from `PricingDate` → `DerivedStartDateTime__std`
7. Save

**Do not modify** the outer-sequence `Assign the EffectiveFrom date to PricingDate` element (seq 6). It may serve other containers downstream. This change makes the CIP DT lookup independent of `PricingDate` entirely for date-range matching.

**Known risk:** `DerivedStartDateTime__std` is derived from `QuoteLineItem.StartDate` + `QuoteLineItem.StartTime`. If `StartTime` is null, the platform defaults the time component to midnight (00:00:00 UTC). Verify that CIP StartDate and EndDate values in the decision table are stored with compatible time-of-day precision so that midnight-UTC line dates fall correctly within expected CIP ranges.

---

### CHANGE 8 — Fix CIP Price Propagation to InputUnitPrice (Three-Part Fix) — **CONFIRMED VERIFIED**

**What and why:**

After CHANGE 7, the `Assigned From Pricing Contract` DT correctly finds the right CIP for each line using `DerivedStartDateTime__std` — confirmed by the waterfall showing the correct per-line price. However, the correct price still does not reach the line's `InputUnitPrice` (Sales Price).

**Root cause — transient procedure variable vs. SalesTransactionItem field scoping:**

Variables in an ExpressionSetDefinition procedure fall into two distinct scopes:

- **Transient procedure variables** (e.g., `ItemContractPrice`, `IsContracted`, `ItemPricingContract`): Exist only at procedure-level (header) context. When a DT element writes to a transient procedure variable via an explicit output parameter mapping, that write goes to the **shared/header scope** — last-write-wins across all lines in the batch. The outer procedure processes ALL lines through seq 10 (the CIP DT container) before any line enters seq 11. After all contracted lines execute through seq 10, `ItemContractPrice` at the procedure level holds the last DT write across the batch (e.g., $8,999 from the last line processed). The Assignment element `Assign ItemContractPrice to InputUnitPrice` in seq 11 then reads this header-level value and applies $8,999 to every contracted line regardless of their individual CIP year.

- **SalesTransactionItem fields** (e.g., `ListPrice`, `InputUnitPrice`, `DerivedStartDateTime__std`): Map to actual `QuoteLineItem` record fields; resolve at per-line scope. The `Assigned From Pricing Contract` List Price BKM's **implicit platform behavior** writes the matched CIP price to the current line's per-line `ListPrice` field as each line processes through seq 10. This per-line `ListPrice` holds the correct value for each contracted line when seq 11 runs.

**The real fix (Part C):** Change the Assignment source from `ItemContractPrice` (transient procedure variable, header-scoped) to `ListPrice` (SalesTransactionItem field, per-line). When the Assignment reads `ListPrice`, it reads the current line's per-line value — the correct per-line CIP price for that line.

The fix has three parts:

**Part A** adds `InputUnitPrice` as an explicit DT output mapping (`ListPrice DT column → InputUnitPrice procedure variable`). This was expected to set `InputUnitPrice` per-line directly from the DT, but it does **not** work as intended — explicit DT output parameter mappings write to procedure-level (header) scope, same problem as `ItemContractPrice`. Part A is harmless and left in place but is NOT the effective fix.

**Part B** simplifies the seq 11 filter to `ItemContractPrice IS NOT NULL AND InputUnitPrice IS NULL`. This prevents the Assignment from running for any line where `InputUnitPrice` is already set. After Part C applies the correct per-line `ListPrice` to `InputUnitPrice` via the Assignment, Part B acts as a guard ensuring no downstream element overrides it.

**Part C (the real fix)** changes the source inside the `AssignItemContractPricetoInputUnitPrice` Assignment element from `ItemContractPrice` to `ListPrice`. The per-line `ListPrice` field holds the correct per-line CIP price (written by the List Price BKM's implicit platform behavior in seq 10), so this Assignment correctly propagates the right price to `InputUnitPrice` for each contracted line independently.

---

#### CHANGE 8 — Part A: Add `InputUnitPrice` as a Direct DT Output

**Where to find it:** Inside the conditional group **Set List Price for Lines With Contract Pricing** → the List Price element `Assigned From Pricing Contract` (seq 2) — the same element modified in CHANGE 2 and CHANGE 7.

**Current output parameters:**

| DT Output Column | Mapped Procedure Variable |
|---|---|
| DiscountType | `ItemContractDiscountType` |
| DiscountValue | `ItemContractDiscountValue` |
| ListPrice | `ItemContractPrice` |
| IsContracted | `IsContracted` |

**Target output parameters (add one row):**

| DT Output Column | Mapped Procedure Variable |
|---|---|
| DiscountType | `ItemContractDiscountType` |
| DiscountValue | `ItemContractDiscountValue` |
| ListPrice | `ItemContractPrice` |
| ListPrice | `InputUnitPrice` ← **ADD THIS ROW** |
| IsContracted | `IsContracted` |

**Steps:**
1. Open the conditional group **Set List Price for Lines With Contract Pricing**
2. Click the **Assigned From Pricing Contract** List Price element → **Edit**
3. Scroll to the **Output Rule Variables** section
4. Verify the existing rows: `DiscountType → ItemContractDiscountType`, `DiscountValue → ItemContractDiscountValue`, `ListPrice → ItemContractPrice`, `IsContracted → IsContracted`
5. Add a **new output row**:
   - **DT Output Column:** `ListPrice` (same column as the `ItemContractPrice` row above)
   - **Mapped Procedure Variable:** `InputUnitPrice`
6. Save

**What this achieves (limited):** The explicit DT output parameter mapping writes to the **procedure-level header scope**, NOT per-line. After all contracted lines process through seq 10, the procedure-level `InputUnitPrice` holds only the last DT write across the batch — this does NOT reliably set per-line `InputUnitPrice`. Part A is **not the effective fix** on its own. It is left in place as it is harmless, but Part C is required to actually propagate the correct per-line CIP price.

---

#### CHANGE 8 — Part B: Simplify the Seq 11 Filter to Prevent Override

**Why Part B is required:** The `Assigned From Pricing Contract` List Price type element also implicitly sets `ListPrice = CIP price` for the line (platform behavior of all List Price BKMs). After Part A, `InputUnitPrice = $7,999` and `ListPrice = $7,999` for the Year 2 line. The seq 11 filter condition `InputUnitPrice = ListPrice` evaluates TRUE, the filter passes, and the header-scoped Assignment reads `ItemContractPrice = $8,999` (the last DT write across all lines) and overrides `InputUnitPrice` back to $8,999. Part B eliminates this code path.

**Where to find it:** Inside the conditional group **Set Input Unit Price for Lines With Contract Pricing** → the Filter element named `Filter lines with contract pricing for which input unit price must be set` (seq 1).

**Current state (4 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Item Contract Price | Is Not Null | — |
| 2 | Input Unit Price | Is Null | — |
| 3 | List Price | Is Not Null | — |
| 4 | Input Unit Price | Equals | `ListPrice` (field reference) |

Logic: `1 AND (2 OR (3 AND 4))`

**Target state (2 conditions):**

| # | Field | Operator | Value |
|---|-------|----------|-------|
| 1 | Item Contract Price | Is Not Null | — |
| 2 | Input Unit Price | Is Null | — |

Logic: `1 AND 2` (All Conditions Are Met)

**Steps:**
1. Open the conditional group **Set Input Unit Price for Lines With Contract Pricing**
2. Click the Filter element **Filter lines with contract pricing for which input unit price must be set**
3. Click **Edit**
4. Delete conditions 3 and 4 (the `List Price IS NOT NULL` and `Input Unit Price = ListPrice` rows)
5. Confirm only conditions 1 and 2 remain: `Item Contract Price IS NOT NULL` and `Input Unit Price IS NULL`
6. Set filter logic: **All Conditions Are Met** (logic string: `1 AND 2`)
7. Save

**What this achieves:** After Part C (below) sets per-line `InputUnitPrice = ListPrice`, condition 2 (`Input Unit Price IS NULL`) becomes FALSE for contracted lines. The filter fails. The Assignment cannot override the correct per-line value.

**Amendment regression note:** For standard amendment lines, `ItemContractPrice` is null (no CIP match) → condition 1 fails → filter fails — no regression.

---

#### CHANGE 8 — Part C: Change Assignment Source from `ItemContractPrice` to `ListPrice` (The Real Fix)

**Why Part C is required and why it works:**

The Assignment element `AssignItemContractPricetoInputUnitPrice` inside the conditional group **Set Input Unit Price for Lines With Contract Pricing** (seq 11) is intended to copy the CIP price into `InputUnitPrice`. Before this fix, its source was `ItemContractPrice` — a transient procedure variable that lives at procedure-level (header) scope. Because the outer procedure runs ALL lines through seq 10 before any line enters seq 11, `ItemContractPrice` at the header level holds only the last DT write from seq 10 (e.g., $8,999 from the last contracted line processed), overwriting all lines with that single value.

The `Assigned From Pricing Contract` List Price BKM's **implicit platform behavior** writes each contracted line's matched CIP price to that line's per-line `ListPrice` field (a SalesTransactionItem field). When the Assignment reads `ListPrice` instead of `ItemContractPrice`, it reads the current line's per-line value — the correct CIP price for that specific line.

**Where to find it:** Inside the conditional group **Set Input Unit Price for Lines With Contract Pricing** → the Assignment element named `Assign ItemContractPrice to InputUnitPrice` (seq 2). Note: after this change the label updates to `Assign ListPrice to InputUnitPrice` but the element name (`AssignItemContractPricetoInputUnitPrice`) stays the same.

**Current state (source = `ItemContractPrice`):**

In the Assignment element configuration, under the assignment row:
- **Input (source):** `ItemContractPrice`
- **Output (target):** `InputUnitPrice`

**Target state (source = `ListPrice`):**

- **Input (source):** `ListPrice`
- **Output (target):** `InputUnitPrice`

**Steps:**
1. Open the conditional group **Set Input Unit Price for Lines With Contract Pricing**
2. Click the Assignment element **Assign ItemContractPrice to InputUnitPrice** (seq 2) → **Edit**
3. Locate the assignment row: source `ItemContractPrice`, target `InputUnitPrice`
4. Change the source from `ItemContractPrice` → `ListPrice`
5. Update the element label to `Assign ListPrice to InputUnitPrice` (optional but keeps the UI accurate)
6. Save

**What this achieves:** For each contracted line, when the Assignment runs in seq 11, it reads the current line's per-line `ListPrice` — the value the List Price BKM implicitly wrote for that specific line in seq 10. Each line receives its own correct per-line CIP price in `InputUnitPrice`. Year 1 lines get $8,999. Year 2 lines get $7,999. The batch-scope problem with `ItemContractPrice` is bypassed entirely.

---

### CHANGE 10A — Add `ItemPricingContract IS NULL` Condition to LT Net Price Filter

**Problem:** On amendment quotes where `PricingContractId` is set, the `List Container` (outer seq 7) fires before the CIP container (outer seq 10). Its inner filter `Set Net Unit Price for Last Transaction Pricing if missing` matched all LT lines where `NetUnitPrice IS NULL` and locked in the asset price — BEFORE CIP ran. By the time CIP fired and set `InputUnitPrice`, `NetUnitPrice` was already locked. The CIP price never became the final Sales Price.

**Element modified:** `Set Net Unit Price for Last Transaction Pricing if missing` (AdvancedListFilter, seq 1 inside `List Container`)

**Before:**
- Condition logic: `1 AND 2 AND 3`
- Condition 1: `ItemPricingSource IS NOT NULL`
- Condition 2: `ItemPricingSource EQUALS LastTransaction`
- Condition 3: `NetUnitPrice IS NULL`

**After:**
- Condition logic: `1 AND 2 AND 3 AND 4`
- Condition 4 added: `ItemPricingContract IS NULL`

**What this achieves:** Contracted LT lines (amendment lines where a CIP applies) are excluded from the seq 7 lock. Their `NetUnitPrice` stays null until CHANGE 11 (below) explicitly sets it after CIP has run.

---

### CHANGE 11 — New List Group: Set NetUnitPrice for Contracted Last-Transaction Lines

**Problem:** CHANGE 10A prevents contracted LT lines from getting their `NetUnitPrice` set at seq 7. After CIP runs (seq 10) and sets `InputUnitPrice = CIP price`, something must copy `InputUnitPrice → NetUnitPrice` for those lines. Without this, contracted LT amendment lines have a CIP `InputUnitPrice` but a null `NetUnitPrice`.

**Element added:** New outer-level `List Group` container immediately before `Filter lines with last-transaction pricing and assign net total price` (outer seq 23).

**New container:**
- Label: `Set NetUnitPrice for contracted last-transaction lines`
- Seq: inserted between seq 15 and seq 23 at the outer level
- Type: ListGroup

**Children inside new container:**

1. **Filter** (AdvancedListFilter, seq 1):
   - Label: `Filter contracted last-transaction lines for NetUnitPrice assignment`
   - Condition logic: `1 AND 2`
   - Condition 1: `ItemPricingSource EQUALS LastTransaction`
   - Condition 2: `ItemPricingContract IS NOT NULL`

2. **Assignment** (BusinessKnowledgeModel, seq 2):
   - Label: `Assign Contracted InputUnitPrice to NetUnitPrice`
   - Name: `AssignContractedInputUnitPricetoNetUnitPrice`
   - Input: `InputUnitPrice`
   - Output: `NetUnitPrice`

**What this achieves:** After CIP sets `InputUnitPrice = CIP price` (seq 10), this new container picks up contracted LT lines and assigns that CIP price into `NetUnitPrice`. Amendment quote lines priced by a contract now correctly show the CIP price as the Sales Price rather than the last-transaction (asset) price.

**Sequence dependency:** Must run AFTER outer seq 10 (`Set list price for lines with contract pricing`) so `InputUnitPrice` holds the CIP price at execution time.

---

### CHANGE 12 — Add `DerivedStartDateTime__std IS NOT NULL` to CIP List Price Filter

**Problem:** When `Additional API` is added as a bundle child inside `QuantumBit Complete Solution`, pricing fails with "duplicate entries found." Root cause: bundle children added via the configurator have `DerivedStartDateTime__std = null` (no explicit StartDate). The `Contract_Pricing_Entries_Decision_Table` is configured with `doesConsiderNullValue = true` — a null input matches ALL rows. With two CIP records for Additional API (Year 1: Oct 2026–Dec 2026; Year 2: Jan 2027–Sep 2028), the DT returns 2 matching rows for the null-date bundle child → "duplicate entries found" error blocks the save.

**Element modified:** `Filter lines with contract pricing for which list price must be set` (AdvancedListFilter, seq 1 inside `Set list price for lines with contract pricing`, outer seq 10)

**Before:**
- Condition logic: `1`
- Condition 1: `ItemPricingContract IS NOT NULL`

**After:**
- Condition logic: `1 AND 2`
- Condition 2 added: `DerivedStartDateTime__std IS NOT NULL`

**What this achieves:** Lines without an explicit start date (null `DerivedStartDateTime__std`) are excluded from the CIP DT lookup. These are typically bundle children added via the product configurator. They fall through to standard pricebook pricing, which is correct — bundle child pricing is governed by the bundle configuration and bundle-based adjustments, not by the contract's per-line CIP records.

**Side effect — confirmed acceptable:** Bundle children with no start date skip CIP pricing. If a future use case requires CIP pricing on bundle children, those children must have an explicit StartDate set so `DerivedStartDateTime__std` is populated.

**Standalone lines unaffected:** Standalone contracted lines always have a specific StartDate (`DerivedStartDateTime__std IS NOT NULL` → condition passes → CIP DT fires normally).

---

### CHANGES NOT NEEDED — Already Correct in V1

The following filters already have correct `IsContracted` routing in V1 and require no changes. Verify these conditions exist; if they do, proceed.

**Standard Attribute Pricing filter** (`Set Attribute Based Pricing for Lines Without Contract Pricing` → `Filter lines without contract or last-transaction pricing`):
- Conditions: `(IsContracted IS NULL OR IsContracted EQUALS false) AND ItemPricingSource NOT EQUALS LastTransaction`
- Logic: `(1 OR 2) AND 3`
- **No change needed**

**Standard Volume Discount filter** (`Apply Volume Based Discounts to Lines Without Contract or Last Transaction Pricing` → `Filter lines without contract or last-transaction pricing`):
- Conditions: same as above — `(IsContracted IS NULL OR IsContracted EQUALS false) AND ItemPricingSource NOT EQUALS LastTransaction`
- Logic: `(1 OR 2) AND 3`
- **No change needed**

---

## SECTION 5 — Activation

Once all CHANGE 1–12 edits are complete on V2:

1. From the V2 version, click **Activate**
2. If V1 is still active, deactivate it first (V1 should already be inactive from the preliminary step, but confirm)
3. Confirm V2 is now the active version with rank 2

---

## SECTION 6 — Verification

### 6A — Check line-level PricingContractId propagation

After any reprice on a quote that has `Quote.PricingContractId` set:

```bash
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' data query \
  --query 'SELECT Id, PricingContractId, UnitPrice FROM QuoteLineItem WHERE QuoteId = ''<QuoteId>''' \
  --target-org <alias> --json"
```

Expected: All line items show `PricingContractId` matching the header `Quote.PricingContractId`.

### 6B — Check pricing waterfall execution

```bash
powershell.exe -Command "& 'C:\Program Files\sf\bin\sf.cmd' data query \
  --query 'SELECT Id, Name, PricingAPIExecutionId, Status, CalculatedValue FROM PricingProcessExecution WHERE PricingAPIExecution.QuoteId = ''<QuoteId>'' ORDER BY CreatedDate DESC LIMIT 50' \
  --target-org <alias> --json"
```

Confirm the `AssignedFromPricingContract` step appears in the execution log with a matched result and `IsContracted = true`.

### 6C — Confirm CIP price applied

Check that `UnitPrice` and `NetUnitPrice` on the line match the expected price from the `Contract Pricing Entries` decision table for the relevant contract + product + date combination.

### 6E — Multi-CIP date range test (validates CHANGE 7)

Create or use a quote with two lines for the same product, each with a `StartDate` in a different CIP date range (e.g., Year 1 and Year 2 CIPs with non-overlapping effective dates). After repricing:

- Line with Year 1 StartDate → UnitPrice = Year 1 CIP price
- Line with Year 2 StartDate → UnitPrice = Year 2 CIP price

If both lines return the same price despite different StartDates, `PricingDate` is not resolving per-line. Try changing the CHANGE 7 input from `StartDate` to `DerivedStartDateTime__std` and reprice again.

### 6F — Multi-CIP date range test for InputUnitPrice propagation (validates CHANGE 8)

Use the same two-line quote from 6E (one line with a Year 1 StartDate, one with a Year 2 StartDate). After applying CHANGE 8 and repricing:

- Line with Year 1 StartDate → **Sales Price = Year 1 CIP price** (e.g., $8,999)
- Line with Year 2 StartDate → **Sales Price = Year 2 CIP price** (e.g., $7,999)

If both lines show the **same** Sales Price (e.g., both $8,999 despite different StartDates), the seq 11 Assignment is still reading the header-scoped `ItemContractPrice`. Diagnose in order:

1. **Part C** — Open the Assignment element `AssignItemContractPricetoInputUnitPrice` in **Set Input Unit Price for Lines With Contract Pricing** (seq 2). Verify the source is `ListPrice`, not `ItemContractPrice`. This is the most common cause of the symptom.
2. **Part B** — Verify the seq 11 filter has exactly 2 conditions (`Item Contract Price IS NOT NULL` AND `Input Unit Price IS NULL`) with logic `1 AND 2`. If it still has 4 conditions with `1 AND (2 OR (3 AND 4))`, Part B was not saved.
3. **Part A** — Verify the `Assigned From Pricing Contract` element has a second `ListPrice` output row mapping to `InputUnitPrice` in **Output Rule Variables**. Part A alone does not fix the issue (it writes to header scope), but it must be present.

If the waterfall (6E) shows the correct per-line CIP price in `ListPrice` but Sales Price does not match, Part C is missing or incorrect. If the waterfall shows the wrong price for one line, CHANGE 7 needs to be rechecked.

### 6D — Standard amendment regression test

Test a quote that has `ItemPricingSource = LastTransaction` (standard amendment, no pricing contract). Confirm:
- `InputUnitPrice` is **not** overwritten — it retains the asset-derived value from the container
- `IsContracted` remains null (not set to true)
- The line does not enter the contract pricing containers

---

## Decision Table Reference

| Decision Table | API Name / ID | Used by |
|---|---|---|
| Contract Pricing Entries | `0lDjV0000009rTWUAY` | CHANGE 2 — Assigned From Pricing Contract List Price element |
| Contract Pricing Volume Tiers | (verify in org) | CHANGE 4 — Discount Assigned From Pricing Contract Volume Discount element |

### Volume Tier Source Object and Automation Gap

**Source object confirmed:** `ContractItemPriceAdjTier` — a child of `ContractItemPrice` (relationship field `ContractItemPriceId`). Fields include `LowerBound`, `UpperBound`, `TierType`, `TierValue`. Both the `Contract Pricing Adjustment Tiers` and `Contract Pricing Volume Tiers` DTs source from this object.

**Critical DT filter behavior:** Both tier DTs filter their source on `ContractItemPriceId.ContractId.StatusCode = Activated`. This means:
- Refreshing either table while the contract is still `Draft` excludes all rows but stamps `LastSyncDate` as current — the table looks fresh but holds nothing
- The `RLM_Contract_Activation_Refresh_Pricing_Tables` flow (After Save, fires when `StatusCode` changes to `Activated`) refreshes all three pricing DTs in sequence — this is the correct trigger point
- Always verify `Contract_Pricing_Volume_Tiers.LastSyncDate` advanced after activation as the signal that tiers are live in the lookup

**Automation gap — `ContractItemPriceAdjTier` records are not auto-generated:** The `createContract` platform invocable (called by `RLM_CreateContractFromQuote`) creates `ContractItemPrice` records from quote line pricing but does **not** create `ContractItemPriceAdjTier` records. No flow, trigger, or automation in the standard RLM platform populates tier records at contract creation time from quote line volume PAS tiers. This is **missing automation that must be built** for volume contract pricing to work end-to-end. Until tier records exist under each CIP, the `Contract Pricing Volume Tiers` DT will always return no match regardless of quantity.

**Recommended approach:** A post-contract-creation step (Apex, Flow invocable, or After Save flow on `ContractItemPrice`) should read the source quote line's `PriceAdjustmentScheduleId`, walk its `PriceAdjustmentTier` records, and insert corresponding `ContractItemPriceAdjTier` rows. This must run **before** contract activation so the rows exist when the DT refresh fires.

**Bundle child open question:** A `QuoteLineItem` that is a bundle child may not receive a `ContractItemPrice` from the `createContract` action — needs testing before building the tier generation step.

---

### Native Limitation: No Product Category Filtering

The standard `Contract Pricing Entries` DT has `ProductSellingModelId` as a **Required Equals** condition. This means:

- Every `ContractItemPrice` row must match an exact product + PSM combination
- **Category-level CIPs cannot be added to this table** — a category rule has no PSM, and a blank PSM value in a data row only matches when the lookup input is also null (never true for a real quote line)
- This is NOT solvable by leaving PSM blank in a row or by any procedure change — the only way to support category-level pricing with this table is to expand category rules into individual product+PSM rows at contract activation time

**Supported workaround — Generator Pattern:** At contract activation, generate one `ContractItemPrice` row per product+PSM combination for each category rule. The pricing procedure itself requires **no changes** — it continues to look up by product+PSM as normal. Tag generated rows with a custom field (e.g., `SourceType__c = 'CategoryGenerated'`) so they can be distinguished from manual product CIPs. Manual product CIPs take precedence over generated category rows via a narrower or later effective window.

See `memory/design_category_cip_generator.md` for the full design, open decisions (trigger mechanism, category hierarchy depth, cleanup on contract change), and the rationale for this approach over a cloned DT with a second lookup element.

---

## Context Variable Reference

| Variable | Level | SObject Field | Notes |
|---|---|---|---|
| `PricingContract` | Header (SalesTransaction) | `Quote.PricingContractId` | Non-transient; populated before pricing runs via Before Save flow |
| `ItemPricingContract` | Line (SalesTransactionItem) | `QuoteLineItem.PricingContractId` | Non-transient; written back to field after pricing run |
| `ItemContract` | Line | (platform-transient) | Read-only; populated only by ARC amendment engine from asset-contract relationships; null for direct-contract quotes — do NOT change any mapping that uses `ItemContract` as the source |
| `IsContracted` | Line | (transient, not stored) | Set to `true` by the `Assigned From Pricing Contract` DT when a CIP match is found; null at start of every pricing run |
| `ItemContractPrice` | Procedure-level (header, transient) | (transient, not stored) | CIP unit price returned by the `Assigned From Pricing Contract` DT. Despite appearing line-scoped in the DT, explicit DT output parameter mappings write to the **procedure-level header scope** — last-write-wins across all lines in the batch. After all contracted lines execute through seq 10, `ItemContractPrice` holds only the last DT result. **Do not use an Assignment element to read `ItemContractPrice` and write it to another variable across lines** — you will always get the last line's value, not the current line's. CHANGE 8 Part C bypasses this by using `ListPrice` (per-line SalesTransactionItem field) as the Assignment source instead. |
| `ListPrice` | Line (SalesTransactionItem) | `QuoteLineItem.ListPrice` (platform-managed) | The per-line List Price. The `Assigned From Pricing Contract` List Price BKM's **implicit platform behavior** writes the matched CIP price to each contracted line's per-line `ListPrice` field during seq 10. This write is per-line — each contracted line holds its own correct CIP price in `ListPrice` after seq 10 completes. CHANGE 8 Part C reads `ListPrice` as the Assignment source to propagate the correct per-line CIP price into `InputUnitPrice`. |
| `InputUnitPrice` | Line (SalesTransactionItem) | `QuoteLineItem.UnitPrice` | The per-line price that becomes Sales Price. Set by the seq 11 Assignment element `AssignItemContractPricetoInputUnitPrice` (source changed from `ItemContractPrice` → `ListPrice` by CHANGE 8 Part C) for contracted lines. Part B's simplified filter ensures no downstream element re-enters and overrides this value for contracted lines. |
| `PricingDate` | Header-scoped in practice | (transient, not stored) | Set at outer seq 6 from `EffectiveFrom`. Despite `EffectiveFrom` being declared line-level in the context definition, empirical testing confirms it resolves header-scope — all lines get the same `PricingDate`. Assignment elements cannot override this per-line. CHANGE 7 bypasses `PricingDate` entirely for the CIP DT date-range lookup. |
| `DerivedStartDateTime__std` | Line (SalesTransactionItem) | `QuoteLineItem.StartDate` + `StartTime` | Platform-standard per-line DateTime. Resolves at SalesTransactionItem scope within a List Price DT element. Used by CHANGE 7 as the direct StartDate/EndDate input for the CIP DT lookup, replacing `PricingDate`. Time component defaults to midnight UTC when `QuoteLineItem.StartTime` is null. |
