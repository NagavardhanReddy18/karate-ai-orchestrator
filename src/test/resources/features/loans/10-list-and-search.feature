@smoke @regression @loans @data-driven
Feature: List, search, and fetch loan applications

  Background:
    * url baseUrl
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(adminUsername)', password: '#(adminPassword)' }
    * header Authorization = 'Bearer ' + session.token

    # ── Reusable Schemas for Detailed Response Type Checking ──────────────────
    * def loanApplicationSchema =
    """
    {
      id: '#number',
      applicationNumber: '##string',
      firstName: '##string',
      lastName: '##string',
      email: '##string',
      phoneNumber: '##string',
      status: '#string',
      facilityTypeId: '##string',
      segment: '##string',
      loanType: '##string',
      totalAmount: '##number',
      loanAmount: '##number',
      annualIncome: '##number',
      creditScore: '##number',
      submittedBy: '##string',
      assignedTo: '##string',
      createdAt: '##string',
      updatedAt: '##string'
    }
    """

    * def pagedResponseSchema =
    """
    {
      content: '#[] loanApplicationSchema',
      pageable: '#object',
      totalElements: '#number',
      totalPages: '#number',
      last: '#boolean',
      size: '#number',
      number: '#number',
      sort: '#object',
      numberOfElements: '#number',
      first: '#boolean',
      empty: '#boolean'
    }
    """

    * def tatRowSchema = { productCode: '##string', channelCode: '##string', count: '#number', avgTatHours: '#number', minTatHours: '#number', maxTatHours: '#number' }
    * def rejectionReasonSchema = { category: '##string', label: '##string', count: '#number' }
    * def dashboardAnalyticsSchema = { tatByProductChannel: '#[] tatRowSchema', rejectionReasons: '#[] rejectionReasonSchema' }

  @smoke
  Scenario: List all applications (paginated)
    Given path '/v1/loans'
    And param page = 0
    And param size = 10
    When method GET
    Then status 200
    And match response == pagedResponseSchema
    And match response.content == '#array'
    And match response.totalElements == '#number'
    And match response.size == 10
    And match response.number == 0

  @smoke
  Scenario: Get application statistics
    Given path '/v1/loans/statistics'
    When method GET
    Then status 200
    And match response == '#object'
    And match each response == '#number'

  @regression
  Scenario: Search applications by free-text
    Given path '/v1/loans/search'
    And param search = 'John'
    And param page = 0
    And param size = 5
    When method GET
    Then status 200
    And match response == pagedResponseSchema
    And match response.size == 5

  @regression
  Scenario: Get non-existent application returns 404
    Given path '/v1/loans/999999999'
    When method GET
    Then status 404

  @regression
  Scenario: Fetch dashboard analytics
    Given path '/v1/loans/dashboard/analytics'
    When method GET
    Then status 200
    And match response == dashboardAnalyticsSchema

  @regression
  Scenario: List applications by SUBMITTED status
    Given path '/v1/loans/status/SUBMITTED'
    When method GET
    Then status 200
    And match response == '#[] loanApplicationSchema'
    And match each response.status == 'SUBMITTED'

  @regression
  Scenario: Search applications by multiple statuses
    Given path '/v1/loans/search/by-statuses'
    And param statuses = ['SUBMITTED', 'UNDER_REVIEW']
    And param page = 0
    And param size = 10
    When method GET
    Then status 200
    And match response == pagedResponseSchema
    And match each response.content contains { status: '#regex SUBMITTED|UNDER_REVIEW' }

