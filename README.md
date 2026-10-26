# tat-264-contract-pricing-base

**Salesforce Revenue Cloud (Release 264) — Contract Pricing Org Delta**

This repository tracks org-level metadata changes applied to the `tat-264-contract-pricing` Trialforce org (`trailsignup-7230ff3f6f8437.my.salesforce.com`) on top of the [rlm-base-dev](https://github.com/bgaldino/rlm-base-dev) Revenue Cloud Foundations Launchpad baseline.

The `upstream` remote points to `bgaldino/rlm-base-dev`. All contract-pricing-specific changes are committed to `origin` (this repo) on top of that baseline.

---

## Design Reference

The contract pricing design is based on three documents in `_CONTRACT_PRICING_REFERENCE/`:

| Document | Purpose |
|---|---|
| `Contract-Based-Pricing-in-QuantumBit-264.md` | Authoritative SE design reference — CIP types, pricing waterfall, end-to-end flow, known gaps |
| `flow-set-pricing-contract-on-quote.md` | Deployment runbook for the Before Save flow |
| `v2-pricing-procedure-migration-runbook.md` | 8-change V1→V2 migration for `RLM_DefaultPricingProcedure` |

---

## Target Org

| Field | Value |
|---|---|
| **Alias** | `tat-264-contract-pricing` |
| **Instance** | `https://trailsignup-7230ff3f6f8437.my.salesforce.com` |
| **Username** | `trailsignup.7230ff3f6f8437@salesforce.com` |
| **API version** | 68.0 (Release 264 / Winter '27) |

---

## Changes Log

All changes below were deployed to `tat-264-contract-pricing` on **2026-10-26**.

---

### 1. Field-Level Security — `Quote.PricingContractId` and `QuoteLineItem.PricingContractId`

**Why:** `PricingContractId` is a standard lookup field introduced in Release 264 on both `Quote` and `QuoteLineItem`. It must be visible and editable before the Before Save flow can sync it and before the pricing procedure can propagate it to lines.

**What was changed:**

- **`force-app/main/default/permissionsets/RLM_QuantumBit.permissionset-meta.xml`**
  Added `editable: true / readable: true` field permissions for:
  - `Quote.PricingContractId`
  - `QuoteLineItem.PricingContractId`

- **`force-app/main/default/profiles/*.profile-meta.xml`** (75 profiles)
  Minimal partial-profile deployment for all 75 org profiles, each granting:
  - `Quote.PricingContractId` — editable, readable
  - `QuoteLineItem.PricingContractId` — editable, readable

  Deployment was additive — no existing profile permissions were removed.

**Deploy result:** `status: Succeeded` — 76 components deployed (75 profiles + package.xml), 0 errors.

---

### 2. Before Save Flow — `RLM_Set_Pricing_Contract_On_Quote`

**Why:** `Quote.PricingContractId` is the field the pricing procedure reads to identify the contract pricing context. `Quote.ContractId` is the user-facing contract lookup. This flow keeps them in sync on every quote save so no manual population of `PricingContractId` is required.

**What was deployed:**

- **`force-app/main/default/flows/RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml`** (new file)

| Property | Value |
|---|---|
| API Name | `RLM_Set_Pricing_Contract_On_Quote` |
| Object | `Quote` |
| Type | Record-Triggered Flow — Before Save |
| Fires on | Create and Update |
| Entry condition | `{!$Record.PricingContractId} != {!$Record.ContractId}` |
| Action | `$Record.PricingContractId = $Record.ContractId` |
| Status | Active |
| API version | 68.0 |

**Behavior:**

| ContractId | PricingContractId (before) | Flow fires? | PricingContractId (after) |
|---|---|---|---|
| null | null | No | null (unchanged) |
| `800Wt…` | null | Yes | `800Wt…` (set) |
| `800Wt…` | `800Wt…` (same) | No | unchanged |
| `800Wt…B` | `800Wt…A` (different) | Yes | `800Wt…B` (updated) |
| null | `800Wt…` (cleared) | Yes | null (cleared) |

**Note:** Before Save flows run in system context — FLS on the running user does not affect whether the flow executes.

**Deploy result:** `status: Succeeded` — 1 Flow component created, 0 errors.  
**Verified live:** `FlowDefinitionView` query confirmed `TriggerType: RecordBeforeSave`, `IsActive: true`.

---

### 3. Page Layout Changes — Quote and Quote Line Item

**Why:** `PricingContractId` must appear on page layouts and the RLM Lightning record page so users can see the contract context that pricing is using.

**Templates edited** (source of truth — never edit `unpackaged/post_ux/` directly):

| Template file | Change |
|---|---|
| `templates/layouts/base/Quote-RLM Quote Layout.layout-meta.xml` | Added `PricingContractId` (Edit behavior) immediately after `ContractId` |
| `templates/layouts/base/QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml` | Added `PricingContractId` (Edit behavior) after `ListPrice` |
| `templates/layouts/constraints/QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml` | Same addition — constraints template overrides base, so both must be updated |
| `templates/flexipages/base/RLM_Quote_Record_Page.flexipage-meta.xml` | Added `Record.PricingContractId` field component (`identifier: RecordPricingContractIdField`) immediately after `Record.ContractId` |

**Regeneration:** `python scripts/ux/ux_tool.py assemble` rebuilt `unpackaged/post_ux/` from templates (114 items).

**Deployed components:**

| Component | Type | State |
|---|---|---|
| `Quote-RLM Quote Layout` | Layout | Changed |
| `QuoteLineItem-RLM Quote Line Item Layout` | Layout | Changed |
| `RLM_Quote_Record_Page` | FlexiPage | Changed |

**Deploy result:** `status: Succeeded` — 3 components, 0 errors.

---

## Remaining Work

| Item | Status |
|---|---|
| V1 → V2 pricing procedure migration (`RLM_DefaultPricingProcedure`, 8 changes) | Pending |
| Contract Pricing Entries DT verification (source criteria, row count) | Pending |
| End-to-end test: create contract + CIPs → activate → reprice quote | Pending |

---

## Repository Structure (Delta Files)

```
force-app/main/default/
  flows/
    RLM_Set_Pricing_Contract_On_Quote.flow-meta.xml   ← NEW
  permissionsets/
    RLM_QuantumBit.permissionset-meta.xml              ← MODIFIED
  profiles/
    *.profile-meta.xml (75 files)                      ← NEW

templates/
  flexipages/base/
    RLM_Quote_Record_Page.flexipage-meta.xml           ← MODIFIED
  layouts/base/
    Quote-RLM Quote Layout.layout-meta.xml             ← MODIFIED
    QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml  ← MODIFIED
  layouts/constraints/
    QuoteLineItem-RLM Quote Line Item Layout.layout-meta.xml  ← MODIFIED

_CONTRACT_PRICING_REFERENCE/                           ← NEW (design docs)
  Contract-Based-Pricing-in-QuantumBit-264.md
  flow-set-pricing-contract-on-quote.md
  v2-pricing-procedure-migration-runbook.md
```

All other files are inherited unchanged from [bgaldino/rlm-base-dev](https://github.com/bgaldino/rlm-base-dev).

---

## Skills and Tools

Skills for working with this org are in `.cursor/skills/`. Key skills for contract pricing work:

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
