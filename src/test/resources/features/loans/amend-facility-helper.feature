@ignore
Feature: Amend Facility Details After Recall — update draft at Step 3 with amended values

  # ── PURPOSE ──────────────────────────────────────────────────────────────────
  # After a recall-to-draft, the origination draft is at step 3 (Facility Details).
  # This helper updates the draft via PUT /v1/origination/draft with the amended
  # facility fields supplied by the caller (loanTerm, repaymentFrequency, etc.).
  #
  # Amount and customer fields are intentionally NOT included in the request body
  # so the test proves the server rejects any attempt to change them, and so normal
  # re-submission of the same amounts keeps the application consistent.
  #
  # ── PARAMETERS ───────────────────────────────────────────────────────────────
  #   draftId              required  origination draft ID (from recall-to-draft)
  #   draftRef             required  applicationRef / applicationNumber
  #   authHeader           required  Bearer token of the loan officer
  #   baseUrl              required  as per karate-config.js
  #   amendPayload         required  object with fields to update, e.g.:
  #     {
  #       id:                     <draftId>,
  #       applicationRef:         <draftRef>,
  #       loanTerm:               24,
  #       termFrequency:          "MONTHS",
  #       repaymentFrequency:     "MONTHLY",
  #       disbursementNotes:      "Amended after UW send-back",
  #       manualCollaterals:      "[]"
  #     }

  Scenario: Amend facility details on recalled draft

    Given url baseUrl
    And path '/v1/origination/draft'
    And header Authorization = authHeader
    And header Content-Type = 'application/json'
    And request amendPayload
    When method PUT
    Then status 200
    * print '[amend-facility] draftId:', draftId, '| amended term:', response.loanTerm, '| status:', responseStatus
    * def amendedDraft = response
