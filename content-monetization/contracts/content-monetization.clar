;; title: content-monetization

;; Define the contract owner
(define-constant contract-owner tx-sender)

;; Define error codes
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_SUBSCRIPTION_EXISTS (err u102))
(define-constant ERR_SUBSCRIPTION_NOT_FOUND (err u103))
(define-constant ERR_CONTENT_NOT_FOUND (err u104))

(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant ERR_TRANSFER_FAILED (err u106))
(define-constant ERR_INVALID_ROYALTY (err u107))


;; Data maps and variables
(define-map subscriptions { subscriber: principal } { creator: principal, expiry: uint })
(define-map content { content-id: uint } { creator: principal, price: uint, royalty-percentage: uint })
(define-map royalties { creator: principal } { balance: uint })

;; Helper function to check if the caller is the contract owner
(define-private (is-owner)
    (is-eq tx-sender contract-owner)
)

;; Create a new content item
(define-public (create-content (content-id uint) (price uint) (royalty-percentage uint))
    (begin
        ;; Ensure the caller is the contract owner
        (asserts! (is-owner) ERR_NOT_AUTHORIZED)

        ;; Ensure the content ID does not already exist
        (asserts! (is-none (map-get? content { content-id: content-id })) ERR_CONTENT_NOT_FOUND)

        ;; Add the content to the map
        (map-set content { content-id: content-id } { creator: tx-sender, price: price, royalty-percentage: royalty-percentage })
        (ok true)
    )
)


;; Get the royalty balance for a creator
(define-read-only (get-royalty-balance (creator principal))
    (ok (default-to u0 (get balance (map-get? royalties { creator: creator }))))
)

;; Extend subscription
(define-public (extend-subscription (subscriber principal) (creator principal) (duration uint))
    (begin
        ;; Ensure the caller is the contract owner or the subscriber
        (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender subscriber)) ERR_NOT_AUTHORIZED)

        ;; Get the current subscription
        (let (
            (subscription (unwrap! (map-get? subscriptions { subscriber: subscriber }) ERR_SUBSCRIPTION_NOT_FOUND))
            (current-expiry (get expiry subscription))
        )
        ;; Update the subscription expiry
        (map-set subscriptions { subscriber: subscriber } { creator: creator, expiry: (+ current-expiry duration) })

        (ok true)
    )
)
)

;; Get content details
(define-read-only (get-content-details (content-id uint))
    (ok (map-get? content { content-id: content-id }))
)

;; Withdraw royalties for creators
(define-public (withdraw-royalties)
    (let (
        (creator-royalty (unwrap! (map-get? royalties { creator: tx-sender }) ERR_INSUFFICIENT_BALANCE))
        (balance (get balance creator-royalty))
    )
        ;; Ensure creator has royalties to withdraw
        (asserts! (> balance u0) ERR_INSUFFICIENT_BALANCE)
        
        ;; Reset creator balance
        (map-set royalties { creator: tx-sender } { balance: u0 })
        
        ;; Transfer royalties to creator
        (as-contract (stx-transfer? balance tx-sender tx-sender))
    )
)

;; Create premium content with access control
(define-map premium-content-access { content-id: uint, user: principal } { access: bool })

(define-public (create-premium-content (content-id uint) (price uint) (royalty-percentage uint))
    (begin
        ;; Ensure royalty percentage is reasonable (1-50%)
        (asserts! (and (> royalty-percentage u0) (<= royalty-percentage u50)) ERR_INVALID_ROYALTY)
        
        ;; Ensure the content ID does not already exist
        (asserts! (is-none (map-get? content { content-id: content-id })) ERR_CONTENT_NOT_FOUND)
        
        ;; Create premium content entry
        (map-set content { content-id: content-id } 
                 { creator: tx-sender, price: price, royalty-percentage: royalty-percentage })
        
        (ok true)
    )
)


;; Purchase access to premium content
(define-public (purchase-content-access (content-id uint))
    (let (
        (content-details (unwrap! (map-get? content { content-id: content-id }) ERR_CONTENT_NOT_FOUND))
        (creator (get creator content-details))
        (price (get price content-details))
        (royalty-percentage (get royalty-percentage content-details))
    )
        ;; Transfer payment from user to contract
        (try! (stx-transfer? price tx-sender (as-contract tx-sender)))
        
        ;; Calculate creator royalty
        (let (
            (creator-royalty (/ (* price royalty-percentage) u100))
            (current-royalty (default-to { balance: u0 } (map-get? royalties { creator: creator })))
            (new-balance (+ (get balance current-royalty) creator-royalty))
        )
            ;; Update creator royalty balance
            (map-set royalties { creator: creator } { balance: new-balance })
            
            ;; Grant access to content
            (map-set premium-content-access { content-id: content-id, user: tx-sender } { access: true })
            
            (ok true)
        )
    )
)


;; Check if user has access to premium content
(define-read-only (has-premium-access (content-id uint) (user principal))
    (ok (is-some (map-get? premium-content-access { content-id: content-id, user: user })))
)

;; Transfer content ownership
(define-public (transfer-content-ownership (content-id uint) (new-owner principal))
    (let (
        (content-details (unwrap! (map-get? content { content-id: content-id }) ERR_CONTENT_NOT_FOUND))
        (creator (get creator content-details))
    )
        ;; Ensure the caller is the content creator
        (asserts! (is-eq tx-sender creator) ERR_NOT_AUTHORIZED)
        
        ;; Update content ownership
        (map-set content { content-id: content-id } 
                 { creator: new-owner, 
                   price: (get price content-details), 
                   royalty-percentage: (get royalty-percentage content-details) })
        
        (ok true)
    )
)


;; NEW FEATURE: Report content
(define-map content-reports { content-id: uint, reporter: principal } 
    { 
      reason: (string-ascii 100), 
      timestamp: uint,
      resolved: bool
    })

(define-constant ERR_ALREADY_REPORTED (err u114))

;; Report content
(define-public (report-content (content-id uint) (reason (string-ascii 100)))
    (begin
        ;; Ensure content exists
        (asserts! (is-some (map-get? content { content-id: content-id })) ERR_CONTENT_NOT_FOUND)
        
        ;; Ensure hasn't already reported
        (asserts! (is-none (map-get? content-reports 
                         { content-id: content-id, reporter: tx-sender })) 
               ERR_ALREADY_REPORTED)
        
        ;; Create report
        (map-set content-reports { content-id: content-id, reporter: tx-sender }
                { 
                 reason: reason, 
                 timestamp: stacks-block-height,
                 resolved: false
                })
        
        (ok true)
    )
)


;; Content bundles for discounted purchases
(define-map content-bundles { bundle-id: uint } 
    { 
      creator: principal, 
      title: (string-ascii 50), 
      price: uint,
      content-count: uint
    })

;; Creator profile and verification
(define-map creator-profiles { creator: principal } 
    { 
      username: (string-ascii 30), 
      verified: bool, 
      join-height: uint, 
      bio: (string-ascii 280)
    })

(define-constant ERR_PROFILE_EXISTS (err u111))

;; Content rating system
(define-map content-ratings { content-id: uint, user: principal } { rating: uint, timestamp: uint })
(define-map content-avg-ratings { content-id: uint } { total-rating: uint, count: uint, avg-rating: uint })

(define-constant ERR_INVALID_RATING (err u108))

;; Submit a rating for content (1-5 stars)
(define-public (rate-content (content-id uint) (rating uint))
    (begin
        ;; Verify content exists
        (asserts! (is-some (map-get? content { content-id: content-id })) ERR_CONTENT_NOT_FOUND)
        
        ;; Verify rating is between 1 and 5
        (asserts! (and (>= rating u1) (<= rating u5)) ERR_INVALID_RATING)
        
        ;; Verify user has access to content
        (asserts! (unwrap! (has-premium-access content-id tx-sender) ERR_NOT_AUTHORIZED) ERR_NOT_AUTHORIZED)
        
        ;; Record user rating
        (map-set content-ratings { content-id: content-id, user: tx-sender } 
                { rating: rating, timestamp: stacks-block-height })
        
        ;; Update average rating
        (let (
            (current-avg (default-to { total-rating: u0, count: u0, avg-rating: u0 } 
                         (map-get? content-avg-ratings { content-id: content-id })))
            (total (+ (get total-rating current-avg) rating))
            (count (+ (get count current-avg) u1))
        )
            (map-set content-avg-ratings { content-id: content-id }
                    { total-rating: total, 
                      count: count, 
                      avg-rating: (/ total count) })
            
            (ok true)
        )
    )
)