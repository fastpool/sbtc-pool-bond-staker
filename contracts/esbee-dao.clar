;; Esbee DAO
;;
;; Operator of `bond-staker`, driven by member vote. Puts the five operator
;; powers behind a proposal: set-next-bond, update-bond-registration,
;; trust/distrust-signer-manager, update-operator, sweep-unattributed-principal.
;; Weight = sqrti(committed sats); queued deposits do not count.
;; A proposal needs: voting period, quorum, supermajority, execution delay,
;; execution window, unchanged epoch. Calls out via `as-contract?` so the DAO
;; is the operator. Install: update-operator(.esbee-dao, true), then retire
;; the old operator. `bind-next-bond` stays permissionless; votes set the floor.

(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

(define-constant ERR_NOT_A_MEMBER (err u5001))
(define-constant ERR_NO_LIVE_EPOCH (err u5002))
(define-constant ERR_UNKNOWN_PROPOSAL (err u5003))
(define-constant ERR_VOTING_CLOSED (err u5004))
(define-constant ERR_VOTING_OPEN (err u5005))
(define-constant ERR_ALREADY_VOTED (err u5006))
(define-constant ERR_NO_QUORUM (err u5007))
(define-constant ERR_REJECTED (err u5008))
(define-constant ERR_TOO_EARLY (err u5009))
(define-constant ERR_EXPIRED (err u5010))
(define-constant ERR_ALREADY_EXECUTED (err u5011))
(define-constant ERR_WRONG_KIND (err u5012))
(define-constant ERR_EPOCH_MOVED (err u5013))
(define-constant ERR_WRONG_TARGET (err u5014))

;;; How long each stage lasts, in burn blocks

;; ~2 days.
(define-constant VOTING_PERIOD u288)

;; ~1 day after voting ends before execution; room to `request-exit`.
(define-constant EXECUTION_DELAY u144)

;; ~1 week to execute after the delay; expired proposals are void.
(define-constant EXECUTION_WINDOW u1008)

;;; What it takes to pass

;; Turnout required, in bips of sqrti(epoch total-shares) -- a lower bound on
;; the sum of member weights, hence set high.
(define-constant QUORUM_BIPS u3000)

;; Yes share of votes cast required, in bips.
(define-constant APPROVAL_BIPS u6000)

(define-constant MAX_BIPS u10000)

;;; Proposals

(define-data-var proposal-count uint u0)

(define-map proposals
  uint
  {
    ;; One of: trust-signer, distrust-signer, signer-change, operator-change,
    ;; next-bond, sweep. Parameters below are typed fields; each kind uses some.
    kind: (string-ascii 24),
    code-hash: (optional (buff 32)),
    target: (optional principal),
    previous: (optional principal),
    enabled: (optional bool),
    index: (optional uint),
    proposer: principal,
    ;; `epoch-count` at proposal time; execution requires it unchanged.
    epoch: uint,
    created-at: uint,
    voting-ends-at: uint,
    yes: uint,
    no: uint,
    executed: bool,
  }
)

(define-map votes
  {
    proposal: uint,
    voter: principal,
  }
  {
    weight: uint,
    support: bool,
  }
)

;;; Read-only

;; sqrti of the member's committed shares; 0 for non-members.
(define-read-only (get-weight (who principal))
  (match (contract-call? .bond-staker get-settled-member who)
    record (sqrti (get shares record))
    u0
  )
)

;; Required turnout; 0 without a live epoch, so proposing requires one.
(define-read-only (get-quorum)
  (match (contract-call? .bond-staker get-live-epoch)
    live (/ (* (sqrti (get total-shares live)) QUORUM_BIPS) MAX_BIPS)
    u0
  )
)

(define-read-only (get-proposal (id uint))
  (map-get? proposals id)
)

(define-read-only (get-vote
    (id uint)
    (voter principal)
  )
  (map-get? votes {
    proposal: id,
    voter: voter,
  })
)

(define-read-only (get-proposal-count)
  (var-get proposal-count)
)

;; All execution conditions for `id`; `ready` is their conjunction.
(define-read-only (get-status (id uint))
  (match (map-get? proposals id)
    proposal (let (
        (cast (+ (get yes proposal) (get no proposal)))
        (quorum (get-quorum))
        (executable-from (+ (get voting-ends-at proposal) EXECUTION_DELAY))
        (voting-open (< burn-block-height (get voting-ends-at proposal)))
        (met-quorum (>= cast quorum))
        (approved (and
          (> cast u0)
          (>= (/ (* (get yes proposal) MAX_BIPS) cast) APPROVAL_BIPS)
        ))
        (same-epoch (is-eq (get epoch proposal) (current-epoch)))
        (expired (>= burn-block-height (+ executable-from EXECUTION_WINDOW)))
      )
      (some {
        voting-open: voting-open,
        votes-cast: cast,
        quorum: quorum,
        met-quorum: met-quorum,
        approved: approved,
        same-epoch: same-epoch,
        executable-from: executable-from,
        expired: expired,
        executed: (get executed proposal),
        ready: (and
          (not voting-open)
          met-quorum
          approved
          same-epoch
          (not expired)
          (not (get executed proposal))
          (>= burn-block-height executable-from)
        ),
      })
    )
    none
  )
)

(define-read-only (current-epoch)
  (get epoch-count (contract-call? .bond-staker get-config))
)

;;; Raising a proposal -- one typed entry point per kind

(define-private (open-proposal (fields {
  kind: (string-ascii 24),
  code-hash: (optional (buff 32)),
  target: (optional principal),
  previous: (optional principal),
  enabled: (optional bool),
  index: (optional uint),
}))
  (let ((id (var-get proposal-count)))
    (asserts! (> (get-weight tx-sender) u0) ERR_NOT_A_MEMBER)
    ;; Without a live epoch the quorum is 0.
    (asserts! (is-some (contract-call? .bond-staker get-live-epoch))
      ERR_NO_LIVE_EPOCH
    )

    (map-set proposals id
      (merge fields {
        proposer: tx-sender,
        epoch: (current-epoch),
        created-at: burn-block-height,
        voting-ends-at: (+ burn-block-height VOTING_PERIOD),
        yes: u0,
        no: u0,
        executed: false,
      })
    )
    (var-set proposal-count (+ id u1))
    (print (merge { topic: "propose" } (unwrap-panic (map-get? proposals id))))
    (ok id)
  )
)

(define-constant NO_HASH none)
(define-constant NO_PRINCIPAL none)
(define-constant NO_FLAG none)
(define-constant NO_INDEX none)

(define-public (propose-trust-signer (code-hash (buff 32)))
  (open-proposal {
    kind: "trust-signer",
    code-hash: (some code-hash),
    target: NO_PRINCIPAL,
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
    index: NO_INDEX,
  })
)

(define-public (propose-distrust-signer (code-hash (buff 32)))
  (open-proposal {
    kind: "distrust-signer",
    code-hash: (some code-hash),
    target: NO_PRINCIPAL,
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
    index: NO_INDEX,
  })
)

(define-public (propose-signer-change
    (manager principal)
    (old-manager principal)
  )
  (open-proposal {
    kind: "signer-change",
    code-hash: NO_HASH,
    target: (some manager),
    previous: (some old-manager),
    enabled: NO_FLAG,
    index: NO_INDEX,
  })
)

(define-public (propose-operator-change
    (who principal)
    (enabled bool)
  )
  (open-proposal {
    kind: "operator-change",
    code-hash: NO_HASH,
    target: (some who),
    previous: NO_PRINCIPAL,
    enabled: (some enabled),
    index: NO_INDEX,
  })
)

;; Floor for `bind-next-bond`: index N+1 skips bond N. Read at bind time, so
;; the vote must complete before the bond becomes bindable.
(define-public (propose-next-bond (index uint))
  (open-proposal {
    kind: "next-bond",
    code-hash: NO_HASH,
    target: NO_PRINCIPAL,
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
    index: (some index),
  })
)

(define-public (propose-sweep (recipient principal))
  (open-proposal {
    kind: "sweep",
    code-hash: NO_HASH,
    target: (some recipient),
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
    index: NO_INDEX,
  })
)

;;; Voting

;; Weight is read and recorded at vote time; one vote per member per proposal.
(define-public (vote
    (id uint)
    (support bool)
  )
  (let (
      (proposal (unwrap! (map-get? proposals id) ERR_UNKNOWN_PROPOSAL))
      (weight (get-weight tx-sender))
    )
    (asserts! (< burn-block-height (get voting-ends-at proposal))
      ERR_VOTING_CLOSED
    )
    (asserts! (> weight u0) ERR_NOT_A_MEMBER)
    (asserts!
      (map-insert votes {
        proposal: id,
        voter: tx-sender,
      } {
        weight: weight,
        support: support,
      })
      ERR_ALREADY_VOTED
    )

    (map-set proposals id
      (merge proposal {
        yes: (+ (get yes proposal) (if support
          weight
          u0
        )),
        no: (+ (get no proposal) (if support
          u0
          weight
        )),
      })
    )
    (let ((result {
        proposal: id,
        voter: tx-sender,
        weight: weight,
        support: support,
      }))
      (print (merge { topic: "vote" } result))
      (ok result)
    )
  )
)

;;; Execution -- permissionless once `get-status` reports `ready`

(define-private (authorize-execution
    (id uint)
    (kind (string-ascii 24))
  )
  (let (
      (proposal (unwrap! (map-get? proposals id) ERR_UNKNOWN_PROPOSAL))
      (status (unwrap! (get-status id) ERR_UNKNOWN_PROPOSAL))
    )
    (asserts! (is-eq (get kind proposal) kind) ERR_WRONG_KIND)
    (asserts! (not (get executed proposal)) ERR_ALREADY_EXECUTED)
    (asserts! (not (get voting-open status)) ERR_VOTING_OPEN)
    (asserts! (get met-quorum status) ERR_NO_QUORUM)
    (asserts! (get approved status) ERR_REJECTED)
    (asserts! (get same-epoch status) ERR_EPOCH_MOVED)
    (asserts! (>= burn-block-height (get executable-from status)) ERR_TOO_EARLY)
    (asserts! (not (get expired status)) ERR_EXPIRED)

    (map-set proposals id (merge proposal { executed: true }))
    (print {
      topic: "execute",
      proposal: id,
      kind: kind,
      yes: (get yes proposal),
      no: (get no proposal),
    })
    (ok proposal)
  )
)

(define-public (execute-trust-signer (id uint))
  (let ((proposal (try! (authorize-execution id "trust-signer"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker trust-signer-manager
        (unwrap-panic (get code-hash proposal))
      ))
    )))
  )
)

(define-public (execute-distrust-signer (id uint))
  (let ((proposal (try! (authorize-execution id "distrust-signer"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker distrust-signer-manager
        (unwrap-panic (get code-hash proposal))
      ))
    )))
  )
)

;; Traits cannot be stored: the executor passes them, checked against the vote.
(define-public (execute-signer-change
    (id uint)
    (manager <signer-manager-trait>)
    (old-manager <signer-manager-trait>)
  )
  (let ((proposal (try! (authorize-execution id "signer-change"))))
    (asserts!
      (and
        (is-eq (some (contract-of manager)) (get target proposal))
        (is-eq (some (contract-of old-manager)) (get previous proposal))
      )
      ERR_WRONG_TARGET
    )
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker update-bond-registration manager old-manager))
    )))
  )
)

(define-public (execute-operator-change (id uint))
  (let ((proposal (try! (authorize-execution id "operator-change"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker update-operator
        (unwrap-panic (get target proposal))
        (unwrap-panic (get enabled proposal))
      ))
    )))
  )
)

(define-public (execute-next-bond (id uint))
  (let ((proposal (try! (authorize-execution id "next-bond"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker set-next-bond
        (unwrap-panic (get index proposal))
      ))
    )))
  )
)

(define-public (execute-sweep (id uint))
  (let ((proposal (try! (authorize-execution id "sweep"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker sweep-unattributed-principal
        (unwrap-panic (get target proposal))
      ))
    )))
  )
)
