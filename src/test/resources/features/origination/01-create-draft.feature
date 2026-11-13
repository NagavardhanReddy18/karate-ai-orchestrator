@smoke @regression @origination
Feature: Create and manage origination drafts

  Background:
    * url baseUrl
    # Origination is the Loan Officer's job and /v1/origination/draft is gated on MENU_APP_CREATE,
    # which LOAN_OFFICER holds. Signing in as the officer keeps this feature honest about the role
    # that really performs it, instead of relying on an admin account that happens to hold everything.
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(officerUsername)', password: '#(officerPassword)' }
    * def authHeader = 'Bearer ' + session.token
    * header Authorization = authHeader

  # ─── Smoke: basic draft lifecycle ────────────────────────────────────────────

  @smoke
  Scenario: Create a new origination draft
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    And match response.id == '#number'
    And match response.applicationRef == '#string'

  @smoke
  Scenario: Get list of in-progress drafts
    Given path '/v1/origination/drafts'
    And param status = 'IN_PROGRESS'
    When method GET
    Then status 200
    And match response == '#array'

  # ─── Full draft update flow ───────────────────────────────────────────────────

  @regression
  Scenario: Create draft then update with loan details
    # Step 1 — create blank draft
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef

    # Step 2 — update with loan details
    Given url baseUrl
    And path '/v1/origination/draft'
    And header Authorization = authHeader
    And request
      """
      {
        "id": #(draftId),
        "applicationRef": "#(draftRef)",
        "loanCategory": "RETAIL",
        "customerTypeSelected": "EXISTING",
        "customerId": "100234",
        "loanPurpose": "Home purchase",
        "loanAmount": 500000,
        "loanAmountCurrency": "INR",
        "totalAmount": 600000,
        "totalAmountCurrency": "INR",
        "customerContribution": 100000,
        "loanTerm": 36,
        "termFrequency": "MONTHS",
        "selectedProductCode": "TL001",
        "selectedProductName": "Standard Term Loan",
        "interestType": "FIXED",
        "repaymentFrequency": "MONTHLY"
      }
      """
    When method PUT
    Then status 200
    And match response.id == draftId
    And match response.loanAmount == 500000

  @regression
  Scenario: Fetch draft by ID after creating it
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id

    Given url baseUrl
    And path '/v1/origination/draft/' + draftId
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response.id == draftId

  @regression
  Scenario: Fetch draft by application reference
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftRef = response.applicationRef

    Given url baseUrl
    And path '/v1/origination/draft/ref/' + draftRef
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response.applicationRef == draftRef

  @regression
  Scenario: Cannot create a draft without authentication
    # configure headers = null only clears configure-level headers; one-shot headers from Background
    # must be explicitly overridden before the HTTP call
    * configure headers = null
    * header Authorization = ''
    Given url baseUrl
    And path '/v1/origination/draft'
    When method POST
    Then match [401, 403] contains responseStatus
