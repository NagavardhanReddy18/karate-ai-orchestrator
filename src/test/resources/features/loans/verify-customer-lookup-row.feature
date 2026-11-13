@ignore
Feature: Customer Lookup Row Helper

  Scenario: Fetch customer by customerId and assert expected customerName from Excel
    Given url baseUrl + '/v1/customers/' + customerId
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response.fullName == expectedCustomerName
    * karate.log('Verified customer name for ID ' + customerId + ': expected=' + expectedCustomerName + ', actual=' + response.fullName)
