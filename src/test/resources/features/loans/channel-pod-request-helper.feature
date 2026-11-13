@ignore
Feature: Channel Personal Overdraft Request Helper

  @with-doc
  Scenario: Submit with document
    Given url baseUrl + '/v1/channel/personal-overdrafts'
    And header Authorization = 'Bearer ' + authToken
    * def appJsonStr = JSON.stringify(appPayload)
    * def docKey = 'document.National ID Card'
    And multipart file application = { value: '#(appJsonStr)', filename: 'application.json', contentType: 'application/json' }
    And multipart file (docKey) = { read: 'classpath:dummy-document.txt', filename: 'National_ID_Card.pdf', contentType: 'application/pdf' }
    When method post
    * def finalStatus = responseStatus
    * def finalBody = response

  @no-doc
  Scenario: Submit without document
    Given url baseUrl + '/v1/channel/personal-overdrafts'
    And header Authorization = 'Bearer ' + authToken
    * def appJsonStr = JSON.stringify(appPayload)
    And multipart file application = { value: '#(appJsonStr)', filename: 'application.json', contentType: 'application/json' }
    When method post
    * def finalStatus = responseStatus
    * def finalBody = response
