@ignore
Feature: Encrypted login helper — used when the server enforces credential encryption

  Scenario: Perform challenge-response encrypted login
    * configure retry = { count: 24, interval: 5000 }
    Given url baseUrl + '/auth/login-challenge'
    When method GET
    Then status 200

    * def challenge = response
    * def Encryptor = Java.type('com.ird.beyond.lo.test.util.LoginEncryptor')
    * def enc = Encryptor.encrypt(challenge.challengeId, challenge.publicKey, challenge.nonce, password)

    Given url baseUrl + '/auth/login'
    And request { username: '#(username)', challengeId: '#(challenge.challengeId)', encryptedCredential: '#(enc)' }
    And retry until responseStatus != 429
    When method POST
    Then status 200
    * def resultResponse = response
