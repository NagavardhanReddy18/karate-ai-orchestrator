@ignore
Feature: Channel Enterprise Overdraft Request Helper

  @with-doc
  Scenario: Submit with document
    Given url baseUrl + '/v1/channel/enterprise-overdrafts'
    And header Authorization = 'Bearer ' + authToken
    * def appJsonStr = JSON.stringify(appPayload)
    * def docKey = 'document.Certificate of Registration'
    And multipart file application = { value: '#(appJsonStr)', filename: 'application.json', contentType: 'application/json' }
    And multipart file (docKey) = { read: 'classpath:dummy-document.txt', filename: 'Certificate_of_Registration.pdf', contentType: 'application/pdf' }
    When method post
    * def finalStatus = responseStatus
    * def finalBody = response

  @no-doc
  Scenario: Submit without document
    Given url baseUrl + '/v1/channel/enterprise-overdrafts'
    And header Authorization = 'Bearer ' + authToken
    * def appJsonStr = JSON.stringify(appPayload)
    And multipart file application = { value: '#(appJsonStr)', filename: 'application.json', contentType: 'application/json' }
    When method post
    * def finalStatus = responseStatus
    * def finalBody = response
