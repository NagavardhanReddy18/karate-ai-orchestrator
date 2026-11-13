@ignore
Feature: Recall to Draft Helper — flip PENDING_DOCUMENTS back to IN_PROGRESS at Step 3

  # ── PURPOSE ──────────────────────────────────────────────────────────────────
  # When an underwriter or approver sends a loan back to the application phase
  # (UW action: REQUEST_ADDITIONAL_DOCS | RETURN_FOR_DOCS;
  #  Approver action: REQUEST_DOCS)
  # the application lands in PENDING_DOCUMENTS status.
  #
  # The loan officer must then recall the draft via:
  #   POST /v1/loans/{appId}/recall-to-draft
  #
  # This sets:
  #   - Application status:  IN_PROGRESS
  #   - Draft status:        IN_PROGRESS
  #   - Draft currentStep:   3  (Facility Details — first editable step)
  #
  # ── LOCKED FIELDS AFTER RECALL ───────────────────────────────────────────────
  # The server prevents editing of:
  #   - loanAmount / loanAmountCurrency
  #   - customerId / customerName
  #   - loanCategory (RETAIL / ENTERPRISE)
  #
  # Editable fields (facility details):
  #   - loanTerm, termFrequency
  #   - interestType, overriddenInterestRate, repaymentFrequency
  #   - manualCollaterals, settlementMode
  #   - repaymentAccountNumber, feeFundingAccountNumber
  #   - disbursementMode, disbursementDate, disbursementNotes
  #   - documents (upload / update)
  #
  # ── PARAMETERS ───────────────────────────────────────────────────────────────
  #   appId       required  application ID to recall
  #   authHeader  required  Bearer token of the officer who owns the application
  #   baseUrl     required  as per karate-config.js

  Scenario: Recall application to draft for officer editing

    Given url baseUrl
    And path '/v1/loans/' + appId + '/recall'
    And header Authorization = authHeader
    And header Content-Type = 'application/json'
    When method POST
    Then assert responseStatus == 200 || responseStatus == 201
    * def recalledDraftId = response.id
    * def recalledCurrentStep = response.currentStep
    * def recalledStatus = response.status
    * print '[recall-to-draft] appId:', appId, '| draftId:', recalledDraftId, '| step:', recalledCurrentStep, '| status:', recalledStatus
    # Step 3 = Facility Details — confirm draft was reset to the editable point
    * assert recalledCurrentStep == 3
