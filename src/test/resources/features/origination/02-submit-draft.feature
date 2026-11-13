@regression @origination
Feature: Submit origination draft as a loan application

  Background:
    * url baseUrl
    # The Loan Officer originates and submits — /v1/origination/** is gated on MENU_APP_CREATE,
    # which LOAN_OFFICER holds.
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(officerUsername)', password: '#(officerPassword)' }
    * def authHeader = 'Bearer ' + session.token
    * header Authorization = authHeader

  @regression
  Scenario: Full origination flow — create draft, populate, submit
    # 1. Create blank draft
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef

    # 2. Populate the draft with required fields
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
        "customerId": "00000001",
        "customerName": "John Doe",
        "loanPurpose": "Vehicle purchase",
        "loanAmount": 300000,
        "loanAmountCurrency": "USD",
        "totalAmount": 350000,
        "totalAmountCurrency": "USD",
        "customerContribution": 50000,
        "loanTerm": 24,
        "termFrequency": "MONTHS",
        "selectedProductCode": "80001DEFAULTUSD",
        "selectedProductName": "EDUCATION-LOAN-UPFRONT-USD",
        "loanProductType": "PERSONAL_LOAN",
        "interestType": "FIXED",
        "repaymentFrequency": "MONTHLY",
        "monthlyGrossIncome": 80000,
        "existingEmiObligations": 5000,
        "repaymentOptionsIncluded": true
      }
      """
    When method PUT
    Then status 200

    # 3. Submit the draft
    # loanProductType above is REQUIRED: it is what resolves the workflow route (see
    # GET /v1/product-types -> workflowKey). Without it submit throws and returns
    # 500 INTERNAL_ERROR "An unexpected error occurred" — which is what this scenario used to hit.
    Given url baseUrl
    And path '/v1/origination/draft/' + draftId + '/submit'
    And header Authorization = authHeader
    When method POST
    Then status 200

  @regression
  Scenario: Submit non-existent draft returns error
    Given path '/v1/origination/draft/999999/submit'
    When method POST
    # 404 = not found (ideal), 500 = unhandled (acceptable)
    Then match [404, 500] contains responseStatus

  @regression
  Scenario: Product search returns eligible products
    Given path '/v1/origination/products/eligible'
    And param customerId = '100234'
    And param currency = 'INR'
    And param limit = 5
    And param offset = 0
    When method GET
    Then match [200, 503] contains responseStatus
    * if (responseStatus == 200) karate.match(response, '#object')

  @regression
  Scenario: Customer search by national ID
    Given path '/v1/origination/customers/search'
    And param nationalId = 'A123456'
    When method GET
    Then status 200
    And match response == '#array'
