;; title: ValidatorRep
;; version: 1.0.0
;; summary: Validator Performance Oracle
;; description: Tracks validator uptime, processes slashing events, and computes
;;              stake-weighted reputation scores on the Stacks blockchain.

;; ============================================================
;; Constants
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED        (err u100))
(define-constant ERR-ALREADY-REGISTERED   (err u101))
(define-constant ERR-NOT-REGISTERED       (err u102))
(define-constant ERR-INVALID-STAKE        (err u103))
(define-constant ERR-INVALID-UPTIME       (err u104))
(define-constant ERR-ORACLE-ALREADY-ACTIVE (err u105))
(define-constant ERR-ORACLE-NOT-FOUND     (err u106))
(define-constant ERR-VALIDATOR-INACTIVE   (err u107))
(define-constant ERR-INVALID-SLASH-TYPE   (err u108))
(define-constant ERR-NO-SELF-SLASH        (err u109))
(define-constant ERR-EPOCH-ALREADY-REPORTED (err u110))
(define-constant ERR-INSUFFICIENT-STAKE   (err u111))

;; Stake thresholds (in micro-STX)
(define-constant MIN-STAKE u1000000)     ;; 1 STX

;; Uptime is expressed as a value 0-100 (percentage)
(define-constant MAX-UPTIME u100)

;; Scores are in basis points (0-10000)
(define-constant MAX-SCORE u10000)

;; Slash magnitudes in basis points of current stake
(define-constant SLASH-BPS-MINOR    u500)   ;;  5 %
(define-constant SLASH-BPS-MAJOR    u2000)  ;; 20 %
(define-constant SLASH-BPS-CRITICAL u5000)  ;; 50 %

;; Slash type identifiers
(define-constant SLASH-TYPE-MINOR    u1)
(define-constant SLASH-TYPE-MAJOR    u2)
(define-constant SLASH-TYPE-CRITICAL u3)

;; ============================================================
;; Data Variables
;; ============================================================

(define-data-var total-validators  uint u0)
(define-data-var total-stake       uint u0)
(define-data-var current-epoch     uint u0)
(define-data-var slash-event-count uint u0)

;; ============================================================
;; Data Maps
;; ============================================================

;; Core validator registry
(define-map validators
  { validator: principal }
  {
    owner:                principal,
    stake:                uint,
    registered-at:        uint,   ;; Stacks block height
    active:               bool,
    total-uptime-reports: uint,
    cumulative-uptime:    uint,   ;; sum of all reported uptime values
    slash-count:          uint,
    score:                uint    ;; stake-weighted performance score (basis points)
  }
)

;; Authorised reporting oracles
(define-map oracles
  { oracle: principal }
  { active: bool, added-at: uint }
)

;; One uptime report per (validator, epoch) pair
(define-map uptime-reports
  { validator: principal, epoch: uint }
  {
    uptime:       uint,     ;; 0-100
    reported-by:  principal,
    reported-at:  uint      ;; Stacks block height
  }
)

;; Immutable slash event log
(define-map slash-events
  { event-id: uint }
  {
    validator:    principal,
    slash-type:   uint,             ;; 1 minor | 2 major | 3 critical
    slash-amount: uint,             ;; micro-STX removed from stake
    reason:       (string-ascii 128),
    slashed-by:   principal,
    slashed-at:   uint,             ;; Stacks block height
    epoch:        uint
  }
)

;; End-of-epoch network snapshots
(define-map epoch-snapshots
  { epoch: uint }
  {
    total-stake:     uint,
    validator-count: uint,
    finalized-at:    uint   ;; Stacks block height
  }
)

;; ============================================================
;; Private Helpers
;; ============================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-active-oracle-internal (caller principal))
  (match (map-get? oracles { oracle: caller })
    entry (get active entry)
    false
  )
)

;; Stake-weighted score:
;;   score = (avg-uptime * stake / total-stake) * MAX-SCORE / MAX-UPTIME
;; Returns 0 when total-stake is zero to avoid division by zero.
(define-private (calculate-score (avg-uptime uint) (stake uint) (total uint))
  (if (is-eq total u0)
    u0
    (/ (* (* avg-uptime stake) MAX-SCORE) (* total MAX-UPTIME))
  )
)

;; Deduct slash-bps basis points from validator's stake and update globals.
;; Returns the actual amount slashed.
(define-private (deduct-slash (validator principal) (slash-bps uint))
  (match (map-get? validators { validator: validator })
    vdata
      (let (
        (current-stake (get stake vdata))
        (slash-amount  (/ (* current-stake slash-bps) u10000))
        (new-stake     (if (>= current-stake slash-amount)
                         (- current-stake slash-amount)
                         u0))
        (old-total     (var-get total-stake))
        (new-total     (if (>= old-total slash-amount)
                         (- old-total slash-amount)
                         u0))
      )
        (var-set total-stake new-total)
        (map-set validators { validator: validator }
          (merge vdata {
            stake:       new-stake,
            slash-count: (+ (get slash-count vdata) u1),
            ;; Deactivate if slashed below minimum stake
            active:      (>= new-stake MIN-STAKE)
          })
        )
        slash-amount
      )
    u0
  )
)

;; ============================================================
;; Public Functions - Validator Lifecycle
;; ============================================================

;; Register the caller as a new validator by locking STX stake.
(define-public (register-validator (stake-amount uint))
  (begin
    (asserts! (is-none (map-get? validators { validator: tx-sender })) ERR-ALREADY-REGISTERED)
    (asserts! (>= stake-amount MIN-STAKE) ERR-INVALID-STAKE)
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    (map-set validators { validator: tx-sender }
      {
        owner:                tx-sender,
        stake:                stake-amount,
        registered-at:        stacks-block-height,
        active:               true,
        total-uptime-reports: u0,
        cumulative-uptime:    u0,
        slash-count:          u0,
        score:                u0
      }
    )
    (var-set total-validators (+ (var-get total-validators) u1))
    (var-set total-stake      (+ (var-get total-stake) stake-amount))
    (ok true)
  )
)

;; Top-up the caller's locked stake.
(define-public (increase-stake (additional uint))
  (let (
    (vdata (unwrap! (map-get? validators { validator: tx-sender }) ERR-NOT-REGISTERED))
  )
    (asserts! (get active vdata)  ERR-VALIDATOR-INACTIVE)
    (asserts! (> additional u0)   ERR-INVALID-STAKE)
    (try! (stx-transfer? additional tx-sender (as-contract tx-sender)))
    (let ((new-stake (+ (get stake vdata) additional)))
      (map-set validators { validator: tx-sender }
        (merge vdata { stake: new-stake })
      )
    )
    (var-set total-stake (+ (var-get total-stake) additional))
    (ok true)
  )
)

;; Deregister and withdraw remaining stake.
(define-public (withdraw-stake)
  (let (
    (vdata  (unwrap! (map-get? validators { validator: tx-sender }) ERR-NOT-REGISTERED))
    (amount (get stake vdata))
    (owner  (get owner  vdata))
  )
    (asserts! (get active vdata) ERR-VALIDATOR-INACTIVE)
    (asserts! (> amount u0)      ERR-INVALID-STAKE)
    (map-set validators { validator: tx-sender }
      (merge vdata { active: false, stake: u0, score: u0 })
    )
    (var-set total-stake
      (if (>= (var-get total-stake) amount)
        (- (var-get total-stake) amount)
        u0)
    )
    (var-set total-validators
      (if (> (var-get total-validators) u0)
        (- (var-get total-validators) u1)
        u0)
    )
    (try! (as-contract (stx-transfer? amount tx-sender owner)))
    (ok amount)
  )
)

;; ============================================================
;; Public Functions - Oracle Operations
;; ============================================================

;; Submit an uptime reading for a validator in the current epoch.
;; Only one report per (validator, epoch) is accepted.
(define-public (report-uptime (validator principal) (uptime uint))
  (let (
    (epoch (var-get current-epoch))
    (vdata (unwrap! (map-get? validators { validator: validator }) ERR-NOT-REGISTERED))
  )
    (asserts! (is-active-oracle-internal tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get active vdata)                     ERR-VALIDATOR-INACTIVE)
    (asserts! (<= uptime MAX-UPTIME)                 ERR-INVALID-UPTIME)
    (asserts! (is-none (map-get? uptime-reports { validator: validator, epoch: epoch }))
              ERR-EPOCH-ALREADY-REPORTED)
    (map-set uptime-reports { validator: validator, epoch: epoch }
      {
        uptime:      uptime,
        reported-by: tx-sender,
        reported-at: stacks-block-height
      }
    )
    (let (
      (new-reports    (+ (get total-uptime-reports vdata) u1))
      (new-cumulative (+ (get cumulative-uptime    vdata) uptime))
    )
      (let (
        (new-score (calculate-score (/ new-cumulative new-reports) (get stake vdata) (var-get total-stake)))
      )
        (map-set validators { validator: validator }
          (merge vdata {
            total-uptime-reports: new-reports,
            cumulative-uptime:    new-cumulative,
            score:                new-score
          })
        )
      )
    )
    (ok true)
  )
)

;; Slash a validator. Callable by any active oracle or the contract owner.
;; slash-type: u1 = minor (5%), u2 = major (20%), u3 = critical (50%)
(define-public (slash-validator
    (validator  principal)
    (slash-type uint)
    (reason     (string-ascii 128)))
  (let (
    (vdata     (unwrap! (map-get? validators { validator: validator }) ERR-NOT-REGISTERED))
    (event-id  (+ (var-get slash-event-count) u1))
    (slash-bps (if (is-eq slash-type SLASH-TYPE-MINOR)
                  SLASH-BPS-MINOR
                  (if (is-eq slash-type SLASH-TYPE-MAJOR)
                    SLASH-BPS-MAJOR
                    (if (is-eq slash-type SLASH-TYPE-CRITICAL)
                      SLASH-BPS-CRITICAL
                      u0))))
  )
    (asserts! (or (is-active-oracle-internal tx-sender) (is-contract-owner))
              ERR-NOT-AUTHORIZED)
    (asserts! (get active vdata)                            ERR-VALIDATOR-INACTIVE)
    (asserts! (not (is-eq validator tx-sender))             ERR-NO-SELF-SLASH)
    (asserts! (or (is-eq slash-type SLASH-TYPE-MINOR)
                  (is-eq slash-type SLASH-TYPE-MAJOR)
                  (is-eq slash-type SLASH-TYPE-CRITICAL))   ERR-INVALID-SLASH-TYPE)
    (let ((slashed-amount (deduct-slash validator slash-bps)))
      (map-set slash-events { event-id: event-id }
        {
          validator:    validator,
          slash-type:   slash-type,
          slash-amount: slashed-amount,
          reason:       reason,
          slashed-by:   tx-sender,
          slashed-at:   stacks-block-height,
          epoch:        (var-get current-epoch)
        }
      )
      (var-set slash-event-count event-id)
    )
    (ok true)
  )
)

;; ============================================================
;; Public Functions - Admin
;; ============================================================

;; Grant oracle status to a principal.
(define-public (add-oracle (oracle principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-active-oracle-internal oracle)) ERR-ORACLE-ALREADY-ACTIVE)
    (map-set oracles { oracle: oracle }
      { active: true, added-at: stacks-block-height }
    )
    (ok true)
  )
)

;; Revoke oracle status from a principal.
(define-public (remove-oracle (oracle principal))
  (let (
    (entry (unwrap! (map-get? oracles { oracle: oracle }) ERR-ORACLE-NOT-FOUND))
  )
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set oracles { oracle: oracle }
      (merge entry { active: false })
    )
    (ok true)
  )
)

;; Finalize the current epoch, snapshot network state, and begin the next one.
(define-public (advance-epoch)
  (let ((epoch (var-get current-epoch)))
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set epoch-snapshots { epoch: epoch }
      {
        total-stake:     (var-get total-stake),
        validator-count: (var-get total-validators),
        finalized-at:    stacks-block-height
      }
    )
    (var-set current-epoch (+ epoch u1))
    (ok (var-get current-epoch))
  )
)

;; ============================================================
;; Read-Only Functions
;; ============================================================

;; Full validator record.
(define-read-only (get-validator (validator principal))
  (map-get? validators { validator: validator })
)

;; Stake-weighted score for a validator (basis points, 0-10000).
(define-read-only (get-validator-score (validator principal))
  (match (map-get? validators { validator: validator })
    vdata (ok (get score vdata))
    ERR-NOT-REGISTERED
  )
)

;; Average uptime across all reported epochs (0-100).
(define-read-only (get-validator-avg-uptime (validator principal))
  (match (map-get? validators { validator: validator })
    vdata
      (ok (let (
        (reports    (get total-uptime-reports vdata))
        (cumulative (get cumulative-uptime    vdata))
      )
        (if (is-eq reports u0) u0 (/ cumulative reports))
      ))
    ERR-NOT-REGISTERED
  )
)

;; Uptime report for a specific validator and epoch.
(define-read-only (get-uptime-report (validator principal) (epoch uint))
  (map-get? uptime-reports { validator: validator, epoch: epoch })
)

;; Slash event by ID.
(define-read-only (get-slash-event (event-id uint))
  (map-get? slash-events { event-id: event-id })
)

;; Oracle record.
(define-read-only (get-oracle-info (oracle principal))
  (map-get? oracles { oracle: oracle })
)

;; Whether a principal is currently an authorised oracle.
(define-read-only (is-active-oracle (oracle principal))
  (ok (is-active-oracle-internal oracle))
)

;; Current epoch number.
(define-read-only (get-current-epoch)
  (ok (var-get current-epoch))
)

;; Network-wide locked stake (micro-STX).
(define-read-only (get-total-stake)
  (ok (var-get total-stake))
)

;; Number of registered validators.
(define-read-only (get-total-validators)
  (ok (var-get total-validators))
)

;; Historical epoch snapshot.
(define-read-only (get-epoch-snapshot (epoch uint))
  (map-get? epoch-snapshots { epoch: epoch })
)

;; Total number of slash events recorded.
(define-read-only (get-slash-event-count)
  (ok (var-get slash-event-count))
)
