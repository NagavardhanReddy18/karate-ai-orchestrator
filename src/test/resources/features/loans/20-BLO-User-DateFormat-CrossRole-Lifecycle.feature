@cross-role-date-format
Feature: Cross-Role Date Format Lifecycle Validation
  Tests that asymmetric date format preferences across roles (Loan Officer, Underwriter, Approver)
  do not cause data corruption, date parsing failures, or assessment errors during loan origination.

  Background:
    * url baseUrl
    * configure headers = { 'Content-Type': 'application/json' }
    * def authHelper = 'classpath:features/auth/auth.feature'

  Scenario: Verify asymmetric date formats across Loan Officer, Underwriter, and Approver lifecycles
    # ── STEP 1: Set Loan Officer date format to dd/MM/yyyy ──────────────────────
    * def officerLogin = karate.call(authHelper, { username: officerUsername, password: officerPassword })
    * def officerAuth = { Authorization: '#("Bearer " + officerLogin.token)' }
    
    Given path '/auth/me/preferences'
    And headers officerAuth
    And request { dateFormat: 'dd/MM/yyyy' }
    When method PUT
    Then status 200
    And match response.dateFormat == 'dd/MM/yyyy'
    * print ' [DATE FORMAT] Loan Officer (', officerUsername, ') configured to: dd/MM/yyyy'

    # ── STEP 2: Set Underwriter date format to yyyy-MM-dd ────────────────────────
    * def uwLogin = karate.call(authHelper, { username: underwriterUsername, password: underwriterPassword })
    * def uwAuth = { Authorization: '#("Bearer " + uwLogin.token)' }

    Given path '/auth/me/preferences'
    And headers uwAuth
    And request { dateFormat: 'yyyy-MM-dd' }
    When method PUT
    Then status 200
    And match response.dateFormat == 'yyyy-MM-dd'
    * print ' [DATE FORMAT] Underwriter (', underwriterUsername, ') configured to: yyyy-MM-dd'

    # ── STEP 3: Set Approver date format to dd-MMM-yyyy ──────────────────────────
    * def approverLogin = karate.call(authHelper, { username: approver1Username, password: approver1Password })
    * def approverAuth = { Authorization: '#("Bearer " + approverLogin.token)' }

    Given path '/auth/me/preferences'
    And headers approverAuth
    And request { dateFormat: 'dd-MMM-yyyy' }
    When method PUT
    Then status 200
    And match response.dateFormat == 'dd-MMM-yyyy'
    * print ' [DATE FORMAT] Approver (', approver1Username, ') configured to: dd-MMM-yyyy'

    # ── STEP 4: Execute Full Retail Loan Lifecycle with Asymmetric Date Formats ─
    * print ' [LIFECYCLE] Executing full loan lifecycle with active asymmetric date formats...'
    * def lifecycleResult = karate.call('classpath:features/loans/04-BLO-LifeCycle.feature')
    * print ' [LIFECYCLE] Full loan lifecycle completed successfully across all roles!'

    # ── STEP 5: Reset Preferences Back to Standard Default (dd-MM-yyyy) ──────────
    Given path '/auth/me/preferences'
    And headers officerAuth
    And request { dateFormat: 'dd-MM-yyyy' }
    When method PUT
    Then status 200

    Given path '/auth/me/preferences'
    And headers uwAuth
    And request { dateFormat: 'dd-MM-yyyy' }
    When method PUT
    Then status 200

    Given path '/auth/me/preferences'
    And headers approverAuth
    And request { dateFormat: 'dd-MM-yyyy' }
    When method PUT
    Then status 200
    * print ' [DATE FORMAT] Reset all user date formats back to default: dd-MM-yyyy'
