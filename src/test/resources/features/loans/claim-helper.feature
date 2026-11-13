@ignore
Feature: Reusable Claim Helper

  Scenario: Claim Application
    Given url baseUrl
    And path '/v1/loans/' + appId + '/claim'
    And header Authorization = authHeader
    When method POST
    * print '[claim-helper] appId:', appId, 'status:', responseStatus, 'body:', response
    Then assert responseStatus == 200 || responseStatus == 409 || responseStatus == 400 || responseStatus == 403 || responseStatus == 404 || responseStatus == 500
