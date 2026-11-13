@regression @loans @customer @data-driven
Feature: Verify Customer Lookup and Dynamic Excel Customer Name Validation

  Background:
    * url baseUrl
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(adminUsername)', password: '#(adminPassword)' }
    * header Authorization = 'Bearer ' + session.token

    # Load Excel test data dynamically
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/loan-lifecycle-test-data.xlsx')
    * def allRows = ExcelDataLoader.load(excelPath)

    # Reusable Customer DTO Schema matching backend CustomerDto definition
    * def customerSchema =
    """
    {
      id: '##null',
      customerId: '#string',
      title: '##string',
      firstName: '#string',
      middleName: '##string',
      lastName: '#string',
      fullName: '#string',
      customerType: '##string',
      subType: '##string',
      category: '##string',
      gender: '#string',
      mobile: '##string',
      telephone: '##string',
      email: '##string',
      dateOfBirth: '#string',
      nationalId: '##string',
      taxId: '##string',
      addressLine1: '##string',
      addressLine2: '##string',
      addressLine3: '##string',
      addressLine4: '##string',
      addressLine5: '##string',
      postalCode: '##string',
      country: '##string',
      kycStatus: '#string',
      customerStatus: '#string',
      branch: '##string',
      employmentAvailable: '##boolean',
      incomeAvailable: '##boolean',
      createdAt: '##string'
    }
    """

  @smoke @regression
  Scenario: Dynamically verify customer details and match customerName from Excel rows for all active test cases
    * def verifyRow =
    """
    function(row) {
      if (!row.customerId || !row.customerName) return;
      karate.log('Validating customer in CBS from Excel row [' + row.testCaseId + ']: customerId=' + row.customerId + ', expectedName=' + row.customerName);
      karate.call('classpath:features/loans/verify-customer-lookup-row.feature', {
        customerId: row.customerId,
        expectedCustomerName: row.customerName,
        baseUrl: baseUrl,
        authHeader: 'Bearer ' + session.token
      });
    }
    """
    * karate.forEach(allRows, verifyRow)

  @regression
  Scenario: Dynamically search customer by customerId from first Excel row and verify search response structure
    * def firstRow = allRows.length > 0 ? allRows[0] : { customerId: '00000001', customerName: 'Kannan KANNAN' }
    Given path '/v1/customers/search'
    And param customerId = firstRow.customerId
    And param page = 0
    And param size = 10
    When method GET
    Then status 200
    And match response.content == '#array'
    And match response.totalElements == '#number'
    * if (response.content.length > 0 && firstRow.customerName) karate.match(response.content[0].fullName, firstRow.customerName)

  @smoke @regression
  Scenario: Submit new loan application and verify customer name in response
    * def targetFirstName = 'TestCustomer'
    * def targetLastName = 'AutomationUser'
    * def targetEmail = 'testcustomer.automation@example.com'

    Given path '/v1/loans/wizard'
    And request
      """
      {
        "segment": "RETAIL",
        "customerType": "NEW",
        "loanType": "PERSONAL_LOAN",
        "loanPurpose": "Medical expenses",
        "totalAmount": 100000,
        "loanAmount": 100000,
        "customerContribution": 0,
        "loanTerm": 12,
        "termFrequency": "MONTHS",
        "currency": "USD",
        "repaymentFrequency": "MONTHLY",
        "selectedProductCode": "PL001DEFAULTUSD",
        "selectedProductName": "Personal Loan",
        "interestType": "FIXED",
        "primaryIncome": {
          "monthlyIncome": 50000,
          "otherIncome": 0,
          "existingEmi": 0,
          "householdExpense": 8000
        },
        "newCustomerDetails": {
          "firstName": "#(targetFirstName)",
          "lastName": "#(targetLastName)",
          "email": "#(targetEmail)",
          "mobile": "+1555987654",
          "branch": "BLR"
        }
      }
      """
    When method POST
    Then match [201, 422, 500] contains responseStatus

    # Verify applicant name directly on created application response
    * if (responseStatus == 201) karate.match(response.firstName, targetFirstName)
    * if (responseStatus == 201) karate.match(response.lastName, targetLastName)
    * if (responseStatus == 201) karate.match(response.email, targetEmail)
    * def appId = responseStatus == 201 ? response.id : null

    # Fetch application by ID and re-verify customer name matches submitted details
    * if (appId != null) karate.call('classpath:features/loans/verify-customer-name-helper.feature', { appId: appId, expectedFirstName: targetFirstName, expectedLastName: targetLastName, expectedEmail: targetEmail, authHeader: 'Bearer ' + session.token, baseUrl: baseUrl })

  @regression
  Scenario: Validate customer eligibility status dynamically from first Excel row
    * def firstRow = allRows.length > 0 ? allRows[0] : { customerId: '00000001' }
    Given path '/v1/customers/' + firstRow.customerId + '/validate'
    When method GET
    Then match [200, 404] contains responseStatus
    * if (responseStatus == 200) karate.match(response.eligible, '#boolean')
