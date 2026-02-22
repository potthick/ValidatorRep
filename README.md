# ValidatorRep

**Version:** 1.0.0  
**Language:** Clarity (Stacks blockchain)

A validator performance oracle for the Stacks blockchain. Tracks uptime reports submitted by trusted oracles, processes slashing events that reduce locked stake, and computes a stake-weighted reputation score (0–10,000 basis points) for each validator.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Scoring Model](#scoring-model)
- [Slashing](#slashing)
- [Epochs](#epochs)
- [Roles](#roles)
- [Public Functions](#public-functions)
- [Read-Only Functions](#read-only-functions)
- [Error Codes](#error-codes)
- [Constants Reference](#constants-reference)

---

## Overview

ValidatorRep is built around three core ideas:

1. **Stake-weighted scoring.** A validator's reputation score reflects not just their uptime percentage but also their share of total network stake. Higher stake + higher uptime = higher score.
2. **Oracle-gated data submission.** Only authorised oracle principals may submit uptime reports and trigger slashes, keeping performance data trustworthy.
3. **Immutable slash history.** Every slash event is written to an append-only log with its type, amount, reason, and epoch, providing a complete accountability record.

---

## How It Works

```
Owner adds oracle principals
         ↓
Validator calls register-validator(stake-amount) — locks STX
         ↓
Each epoch, oracles call report-uptime(validator, uptime)
  └─ one report per (validator, epoch) enforced
  └─ cumulative average uptime updated
  └─ stake-weighted score recalculated and stored
         ↓
Oracles or owner may call slash-validator(validator, type, reason)
  └─ percentage of stake deducted
  └─ slash event written to immutable log
  └─ validator deactivated if stake falls below MIN-STAKE
         ↓
Owner calls advance-epoch()
  └─ network snapshot recorded
  └─ epoch counter incremented
         ↓
Anyone queries get-validator-score(validator) or get-validator(validator)
```

---

## Scoring Model

Validator scores are expressed in **basis points (0–10,000)** where 10,000 represents the theoretical maximum. The formula is stake-weighted:

```
avg-uptime = cumulative-uptime / total-uptime-reports   (0–100)

score = (avg-uptime × stake / total-stake) × MAX-SCORE / MAX-UPTIME
```

This means two validators with identical uptime will receive different scores if their stake differs — a validator holding a larger share of total network stake earns proportionally more. Conversely, even a validator with perfect uptime receives a lower score if their stake share is small.

The score is recalculated and persisted every time a new uptime report is submitted. It is not time-decayed, but a slash that reduces stake will lower the score on the next uptime report submission.

**Example:** A validator with 80% average uptime and 10% of total stake would score:

```
(80 × 0.10) × 10000 / 100 = 800 bps   (8% of maximum)
```

---

## Slashing

Slashing deducts a percentage of the validator's current locked stake. Three severity levels are supported:

| Slash Type | Constant | Value | Stake Deducted |
|------------|----------|-------|----------------|
| Minor | `SLASH-TYPE-MINOR` | `u1` | 5% |
| Major | `SLASH-TYPE-MAJOR` | `u2` | 20% |
| Critical | `SLASH-TYPE-CRITICAL` | `u3` | 50% |

Slash amounts are calculated as basis points of the validator's **current** stake at the time of the slash, not their original stake. Repeated slashes compound — each one applies to the already-reduced balance.

If a slash reduces the validator's stake below `MIN-STAKE` (1 STX), the validator is automatically deactivated. Deactivated validators cannot receive new uptime reports or further slashes. They retain their history but cannot participate until stake is topped up via `increase-stake` to re-meet the minimum.

Oracles cannot slash themselves (`ERR-NO-SELF-SLASH`). Every slash event is recorded in the immutable `slash-events` map with a sequential event ID.

---

## Epochs

The contract uses an epoch counter to organise uptime reporting. Only one uptime report is accepted per `(validator, epoch)` pair — oracles cannot overwrite or duplicate reports within the same epoch.

At the end of each epoch the contract owner calls `advance-epoch`, which:
1. Writes an immutable snapshot of total network stake and validator count at that block height.
2. Increments the epoch counter, opening a fresh reporting window.

Historical snapshots are queryable via `get-epoch-snapshot`.

---

## Roles

**Contract Owner** — The deploying principal. Manages the oracle registry, advances epochs, and may also slash validators directly.

**Oracles** — Principals authorised by the owner. Submit uptime reports and slash events. Cannot report uptime or slash themselves. Multiple oracles may be active simultaneously.

**Validators** — Any principal that calls `register-validator` and locks at least 1 STX. Self-managed — validators top up their own stake, withdraw it, or deactivate themselves.

---

## Public Functions

### Validator Lifecycle

#### `register-validator (stake-amount uint)`
Registers the calling principal as a validator by transferring `stake-amount` microSTX into the contract. Stake must be at least `MIN-STAKE` (1 STX). Fails if the caller is already registered. Returns `true` on success.

#### `increase-stake (additional uint)`
Tops up the caller's locked stake. The additional amount must be greater than zero. Only active validators may call this. Useful for re-meeting `MIN-STAKE` after a slash has triggered deactivation — though note the validator must be active to call this, so timing matters.

#### `withdraw-stake`
Deregisters the caller and returns their full remaining stake. The validator is marked inactive with a score of zero. Returns the amount of STX withdrawn.

---

### Oracle Operations *(authorised oracles only)*

#### `report-uptime (validator principal) (uptime uint)`
Submits an uptime reading for a validator in the current epoch. `uptime` must be in the range `[0, 100]`. Only one report per `(validator, epoch)` is accepted. Recalculates and stores the validator's updated stake-weighted score. Returns `true` on success.

#### `slash-validator (validator principal) (slash-type uint) (reason string-ascii-128)`
Slashes a validator, deducting a percentage of their current stake and logging the event. Callable by any active oracle or the contract owner. Oracles cannot slash themselves. `slash-type` must be `u1`, `u2`, or `u3`. Returns `true` on success.

---

### Administration *(owner only)*

#### `add-oracle (oracle principal)`
Grants oracle status to a principal. Fails if the principal is already an active oracle.

#### `remove-oracle (oracle principal)`
Revokes oracle status from a principal. The oracle record is preserved but marked inactive.

#### `advance-epoch`
Finalises the current epoch by writing a network snapshot, then increments the epoch counter. Returns the new epoch number.

---

## Read-Only Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `get-validator (validator principal)` | `(optional validator)` | Full validator record including stake, uptime totals, slash count, and score |
| `get-validator-score (validator principal)` | `(response uint err)` | Just the stake-weighted score in basis points |
| `get-validator-avg-uptime (validator principal)` | `(response uint err)` | Average uptime across all reported epochs (0–100) |
| `get-uptime-report (validator principal) (epoch uint)` | `(optional report)` | Uptime report for a specific validator/epoch pair |
| `get-slash-event (event-id uint)` | `(optional event)` | Full slash event record by ID |
| `get-slash-event-count` | `(response uint err)` | Total slash events ever recorded |
| `get-oracle-info (oracle principal)` | `(optional oracle)` | Oracle record including active status and registration block |
| `is-active-oracle (oracle principal)` | `(response bool err)` | Whether a principal is currently an authorised oracle |
| `get-current-epoch` | `(response uint err)` | Current epoch number |
| `get-total-stake` | `(response uint err)` | Total network-locked stake in microSTX |
| `get-total-validators` | `(response uint err)` | Number of currently registered validators |
| `get-epoch-snapshot (epoch uint)` | `(optional snapshot)` | Historical snapshot for a completed epoch |

---

## Error Codes

| Code | Constant | When it's thrown |
|------|----------|-----------------|
| `u100` | `ERR-NOT-AUTHORIZED` | Caller is not an active oracle or the contract owner |
| `u101` | `ERR-ALREADY-REGISTERED` | Validator principal is already registered |
| `u102` | `ERR-NOT-REGISTERED` | Referenced validator has not been registered |
| `u103` | `ERR-INVALID-STAKE` | Stake amount is zero or below `MIN-STAKE` |
| `u104` | `ERR-INVALID-UPTIME` | Uptime value exceeds `MAX-UPTIME` (100) |
| `u105` | `ERR-ORACLE-ALREADY-ACTIVE` | Target principal is already an active oracle |
| `u106` | `ERR-ORACLE-NOT-FOUND` | Target principal has no oracle record |
| `u107` | `ERR-VALIDATOR-INACTIVE` | Validator is deactivated |
| `u108` | `ERR-INVALID-SLASH-TYPE` | Slash type is not `u1`, `u2`, or `u3` |
| `u109` | `ERR-NO-SELF-SLASH` | Oracle attempted to slash themselves |
| `u110` | `ERR-EPOCH-ALREADY-REPORTED` | An uptime report already exists for this validator/epoch pair |
| `u111` | `ERR-INSUFFICIENT-STAKE` | Reserved for future stake validation |

---

## Constants Reference

```clarity
;; Stake & Score Bounds
MIN-STAKE    u1000000   ;; 1 STX minimum stake (microSTX)
MAX-UPTIME   u100       ;; Uptime expressed as 0–100 percentage
MAX-SCORE    u10000     ;; Score expressed in basis points

;; Slash Magnitudes (basis points of current stake)
SLASH-BPS-MINOR     u500    ;;  5%
SLASH-BPS-MAJOR     u2000   ;; 20%
SLASH-BPS-CRITICAL  u5000   ;; 50%

;; Slash Type Identifiers
SLASH-TYPE-MINOR     u1
SLASH-TYPE-MAJOR     u2
SLASH-TYPE-CRITICAL  u3

;; Stake-weighted score formula
;; score = (avg-uptime × stake / total-stake) × MAX-SCORE / MAX-UPTIME
```