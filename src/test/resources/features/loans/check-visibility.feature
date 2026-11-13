Feature: Check Live Scorecards and Product Types Direct

  Background:
    * url 'http://164.52.210.93:9190/api'
    * def adminAuth = karate.call('classpath:features/auth/auth.feature', { username: 'admin1', password: 'Password123' })
    * def adminToken = adminAuth.token

  Scenario: Fetch Scorecards and Product Types Direct
    # 1. Fetch All Scorecards
    Given path '/v1/config/scorecards'
    And param domain = 'LOAN_APPLICATION'
    And header Authorization = 'Bearer ' + adminToken
    When method GET
    Then status 200
    * print '=== ALL SCORECARDS COUNT ===', response.length
    * def scMatch = karate.filter(response, function(x){ return x.code == 'SC_PL005_DYNAMIC' || x.name == 'Scorecard PL005 Dynamic' })
    * print 'Matched Scorecards:', scMatch

    # 2. Fetch All Product Types
    Given path '/v1/product-types'
    And header Authorization = 'Bearer ' + adminToken
    When method GET
    Then status 200
    * print '=== ALL PRODUCT TYPES COUNT ===', response.length
    * def ptMatch = karate.filter(response, function(x){ return x.code == 'PL005_DYNAMIC' })
    * print 'Matched Product Types:', ptMatch
