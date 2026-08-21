;; Esbee DAO
;;
;; The pool's operator, held by its members rather than by a key.
;;
;; `bond-staker` lets an operator do five things: bind the next bond, move the
;; pool between vetted signer managers, add and remove hashes from the trusted
;; list, change who the operators are, and sweep unattributed principal. It can
;; never touch deposits, and it can never stop members leaving. This contract
;; puts four of the five behind a vote.
;;
;; Binding is not among them, and deliberately. A bond has to be bound inside
;; the window pox-5 allows for it, which a vote with a period, a delay and a
;; quorum cannot be relied on to hit; a missed window costs the pool a whole
;; bond period. So binding stays with a keyed operator, and the DAO's hold over
;; it is the one that matters: it decides who the operators are.
;;
;; Install it by having the sitting operator enable it and then retire itself:
;;
;;     bond-staker.update-operator(.esbee-dao, true)     ;; sitting operator
;;     bond-staker.update-operator(<old key>, false)     ;; from the DAO, or a
;;;;                                                        second operator
;;
;; `bond-staker` checks `tx-sender`, so every call out of here is wrapped in
;; `as-contract?` -- that is what makes this contract, rather than the member
;; who pressed the button, the operator.
;;
;; Who votes, and with how much
;;
;; A member's weight is the square root of their committed sats:
;; sqrt-weighted voting, so a holder ten thousand times larger than another has
;; a hundred times the say rather than ten thousand. It is the shape usually
;; meant by "quadratic voting" in a DAO, without the per-voter credit budget
;; that needs an identity system to be worth anything.
;;
;; Only *committed* shares count. A queued deposit is withdrawable on demand, so
;; counting it would let anyone rent a majority for the length of one
;; transaction: deposit, vote, withdraw. Committed sats are locked in the bond
;; for its term, which makes weight something a voter has to actually hold.
;;
;; Nothing passes quietly
;;
;; Silence is not consent, and neither is speed. A proposal has to clear all of:
;;
;;   * a voting period, so it cannot be raised and settled in one block
;;   * a quorum, so an empty room does not decide
;;   * a supermajority of the votes cast
;;   * a delay between passing and executing, so members who dislike the
;;     outcome can `request-exit` before it lands
;;   * an execution window, so a stale mandate cannot be dusted off months later
;;   * the same epoch throughout: if the pool rolls, the membership that voted
;;     is not the membership that would live with it, and the proposal is void
;;
;; Every one of those is a line that has to be crossed in the open: proposing,
;; voting and executing all emit a `print` an indexer can watch.

(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

(define-constant ERR_UNAUTHORIZED (err u400))
(define-constant ERR_NOT_A_MEMBER (err u401))
(define-constant ERR_NO_LIVE_EPOCH (err u402))
(define-constant ERR_UNKNOWN_PROPOSAL (err u403))
(define-constant ERR_VOTING_CLOSED (err u404))
(define-constant ERR_VOTING_OPEN (err u405))
(define-constant ERR_ALREADY_VOTED (err u406))
(define-constant ERR_NO_QUORUM (err u407))
(define-constant ERR_REJECTED (err u408))
(define-constant ERR_TOO_EARLY (err u409))
(define-constant ERR_EXPIRED (err u410))
(define-constant ERR_ALREADY_EXECUTED (err u411))
(define-constant ERR_WRONG_KIND (err u412))
(define-constant ERR_EPOCH_MOVED (err u413))
(define-constant ERR_WRONG_TARGET (err u414))

;;; How long each stage lasts, in burn blocks

;; ~2 days of voting. Long enough that a proposal cannot be raised and settled
;; before anyone has looked at it.
(define-constant VOTING_PERIOD u288)

;; ~1 day between a proposal passing and anyone being able to execute it. This
;; is the members' room to act on an outcome they do not like.
(define-constant EXECUTION_DELAY u144)

;; ~1 week to execute, after which the mandate goes stale. A vote taken under
;; one set of circumstances should not be executable under another.
(define-constant EXECUTION_WINDOW u1008)

;;; What it takes to pass

;; Share of the pool's voting weight that has to turn out, in basis points.
;;
;; Measured against the square root of the epoch's total shares, which is a
;; *lower* bound on the true total of the members' individual roots -- the more
;; evenly held the pool, the further below. So this is a floor rather than an
;; exact fraction, and it is set high to compensate.
(define-constant QUORUM_BIPS u3000)

;; Share of the votes cast that have to be in favour, in basis points.
(define-constant APPROVAL_BIPS u6000)

(define-constant MAX_BIPS u10000)

;;; Proposals

(define-data-var proposal-count uint u0)

(define-map proposals
  uint
  {
    ;; Which of the operator's five powers this asks for.
    kind: (string-ascii 24),
    ;; The parameters, only those the kind uses. Kept as plain fields rather
    ;; than an opaque payload so that what was voted on is legible on chain.
    code-hash: (optional (buff 32)),
    target: (optional principal),
    previous: (optional principal),
    enabled: (optional bool),
    proposer: principal,
    ;; The epoch the pool was in when this was raised. If it rolls, the
    ;; membership that voted is no longer the membership that would live with
    ;; the result.
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

;; A member's say: the square root of their committed sats.
(define-read-only (get-weight (who principal))
  (match (contract-call? .bond-staker get-settled-member who)
    record (sqrti (get shares record))
    u0
  )
)

;; The turnout a proposal needs. Zero before the pool has ever staked, which is
;; why proposing and executing both require a live epoch.
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

;; Everything standing between a proposal and execution, in one read. `ready`
;; is the whole test; the rest says which line is still uncrossed.
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

;;; Raising a proposal
;;
;; One entry point per power, so the parameters are typed and a proposal cannot
;; be raised with the fields of one kind and executed as another.

(define-private (open-proposal (fields {
  kind: (string-ascii 24),
  code-hash: (optional (buff 32)),
  target: (optional principal),
  previous: (optional principal),
  enabled: (optional bool),
}))
  (let ((id (var-get proposal-count)))
    ;; Only a member with something committed may raise one. Nothing else is a
    ;; usable filter here: anyone can hold an address.
    (asserts! (> (get-weight tx-sender) u0) ERR_NOT_A_MEMBER)
    ;; No live epoch means no quorum to clear, which would make every proposal
    ;; a formality.
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

(define-public (propose-trust-signer (code-hash (buff 32)))
  (open-proposal {
    kind: "trust-signer",
    code-hash: (some code-hash),
    target: NO_PRINCIPAL,
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
  })
)

(define-public (propose-distrust-signer (code-hash (buff 32)))
  (open-proposal {
    kind: "distrust-signer",
    code-hash: (some code-hash),
    target: NO_PRINCIPAL,
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
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
  })
)

(define-public (propose-sweep (recipient principal))
  (open-proposal {
    kind: "sweep",
    code-hash: NO_HASH,
    target: (some recipient),
    previous: NO_PRINCIPAL,
    enabled: NO_FLAG,
  })
)

;;; Voting

;; Weight is read now rather than at proposal time, and recorded, so a later
;; change to a member's position cannot rewrite a vote already cast.
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

;;; Execution
;;
;; Anyone may execute a proposal that has cleared every line -- the mandate is
;; the vote, not the executor.

(define-private (authorize-execution
    (id uint)
    (kind (string-ascii 24))
  )
  (let (
      (proposal (unwrap! (map-get? proposals id) ERR_UNKNOWN_PROPOSAL))
      (status (unwrap! (get-status id) ERR_UNKNOWN_PROPOSAL))
    )
    ;; The kind is checked against the entry point, so a mandate for one power
    ;; can never be spent on another.
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

;; The trait references cannot be stored, so the executor supplies them and the
;; contract checks they are the ones that were voted on.
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

(define-public (execute-sweep (id uint))
  (let ((proposal (try! (authorize-execution id "sweep"))))
    (ok (try! (as-contract? ()
      (try! (contract-call? .bond-staker sweep-unattributed-principal
        (unwrap-panic (get target proposal))
      ))
    )))
  )
)
