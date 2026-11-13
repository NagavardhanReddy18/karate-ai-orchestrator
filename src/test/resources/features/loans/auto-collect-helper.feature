@ignore
Feature: Auto Collect All Pending Charges Helper

  Background:
    * url baseUrl
    * configure headers = { Authorization: '#(authHeader)' }

  Scenario: Fetch and collect any pending charges for an application or draft via live API
    # 1. Resolve target application ID if given ID is a draft ID
    * def targetAppId = appId
    Given path '/v1/origination/draft/' + appId
    When method GET
    * def draftData = (responseStatus == 200 && response) ? response : null
    * if (draftData && draftData.linkedApplicationId) targetAppId = draftData.linkedApplicationId
    # A draft with no application behind it yet has no charges of its own. Its id must not be read
    # as an application id: that would collect the charges of whichever application holds that number.
    * if (draftData && !draftData.linkedApplicationId) karate.abort()

    * print '=== AUTO-COLLECT-HELPER resolving charges for targetAppId:', targetAppId, '(input appId:', appId, ')'

    * def collectableCharges = []

    # 2. Fetch live collectable charges from charge-collection API (includes live materialized charges)
    Given path '/v1/charge-collection/' + targetAppId + '/collectable'
    And param includeSettled = false
    When method GET
    * if (responseStatus == 200 && response && karate.sizeOf(response) > 0) collectableCharges = response

    # 2b. Try direct loan-charges API for targetAppId if charge-collection API returned empty
    Given path '/v1/loan-charges/' + targetAppId
    When method GET
    * if (karate.sizeOf(collectableCharges) == 0 && responseStatus == 200 && response) collectableCharges = Array.isArray(response) ? response : [response]

    # 2c. Try direct loan-charges API for input appId if different
    Given path '/v1/loan-charges/' + appId
    When method GET
    * if (karate.sizeOf(collectableCharges) == 0 && responseStatus == 200 && response) collectableCharges = Array.isArray(response) ? response : [response]

    * def rawCharges = collectableCharges
    * print '=== AUTO-COLLECT-HELPER targetAppId:', targetAppId, 'raw charges count:', karate.sizeOf(rawCharges)

    # 3. Resolve Admin Auth Header for collection permission
    # Accounts come from the caller, which takes them from karate-config.js - never from here.
    * def activeAdminU = adminUser
    * def activeAdminP = adminPass
    * def adminAuthHeader = 'Bearer ' + karate.call('classpath:features/auth/auth.feature', { username: activeAdminU, password: activeAdminP }).token

    # 4. Filter for uncollected valid charges
    * def isValidPending = function(c){ return c != null && c.id != null && !c.collected && c.status != 'COLLECTED' && c.status != 'WAIVED'; }
    * def pendingCharges = karate.filter(rawCharges, isValidPending)
    * print '=== AUTO-COLLECT-HELPER pending charges count:', karate.sizeOf(pendingCharges)

    * def resolvedAcct = (typeof accountNumber !== 'undefined' && accountNumber && accountNumber.toString().trim() !== '') ? accountNumber.toString().trim() : ((draftData && draftData.feeFundingAccountNumber) ? draftData.feeFundingAccountNumber : ((draftData && draftData.feeAccountNumber) ? draftData.feeAccountNumber : ((draftData && draftData.repaymentAccountNumber) ? draftData.repaymentAccountNumber : '')))

    # 6. Map parameters into each charge object for sub-scenario invocation
    # Collection mode and waiver reason are the caller's, which takes them from its sheet.
    * def chargeMode = (typeof collectionMode !== 'undefined') ? collectionMode : null
    * def chargeWaiveText = (typeof waiveReason !== 'undefined') ? waiveReason : null
    * def prepareCharge = function(c){ return { id: c.id, targetAcct: resolvedAcct, adminAuthHeader: adminAuthHeader, collectionMode: chargeMode, waiveReason: chargeWaiveText }; }
    * def readyCharges = karate.map(pendingCharges, prepareCharge)

    # 7. Call collection loop natively
    * if (karate.sizeOf(readyCharges) > 0) karate.call('classpath:features/loans/auto-collect-helper.feature@collectSingleCharge', readyCharges)

  @collectSingleCharge
  Scenario: Collect a single charge via accounting ledger endpoint
    * def chgId = __arg.id
    * if (!chgId || chgId == 'null') karate.abort()
    * def currentAcct = __arg.targetAcct
    * def currentAuthHeader = __arg.adminAuthHeader
    * configure headers = { Authorization: '#(currentAuthHeader)', 'Content-Type': 'application/json' }
    * print '=== AUTO-COLLECTING charge ID via charge-collection accounting API:', chgId, 'account:', currentAcct
    Given url baseUrl + '/v1/charge-collection/' + chgId + '/collect'
    And request { collectionMode: '#(__arg.collectionMode)', fundingAccount: '#(currentAcct)' }
    When method POST
    * print '=== Charge collection result status:', responseStatus, 'response:', response
    * def isFailed = (responseStatus != 200 && responseStatus != 201 && responseStatus != 204) || (response && response.status == 'FAILED')
    * def directResult = isFailed ? karate.call('classpath:features/loans/auto-collect-helper.feature@collectViaDirectApi', __arg) : null
    * def stillFailed = isFailed && (directResult == null || (directResult.responseStatus != 200 && directResult.responseStatus != 201))
    * if (stillFailed) karate.call('classpath:features/loans/auto-collect-helper.feature@waiveSingleCharge', __arg)

  @collectViaDirectApi
  Scenario: Settle single charge via direct loan-charges API
    * def chgId = __arg.id
    * if (!chgId || chgId == 'null') karate.abort()
    * def currentAcct = __arg.targetAcct
    * def currentAuthHeader = __arg.adminAuthHeader
    * configure headers = { Authorization: '#(currentAuthHeader)', 'Content-Type': 'application/json' }
    * print '=== Direct loan-charges collect fallback for charge ID:', chgId
    Given url baseUrl + '/v1/loan-charges/' + chgId + '/collect'
    And request { accountNumber: '#(currentAcct)' }
    When method POST
    * print '=== Direct loan-charges result status:', responseStatus

  @waiveSingleCharge
  Scenario: Waive single charge when collection fails
    * def chgId = __arg.id
    * if (!chgId || chgId == 'null') karate.abort()
    * def currentAuthHeader = __arg.adminAuthHeader
    * configure headers = { Authorization: '#(currentAuthHeader)', 'Content-Type': 'application/json' }
    * print '=== AUTO-WAIVING charge ID:', chgId
    Given url baseUrl + '/v1/charge-collection/' + chgId + '/waive'
    And request { reason: '#(__arg.waiveReason)' }
    When method POST
    * print '=== Charge waive result status:', responseStatus, 'response:', response
    * def crId = (response && response.id) ? response.id : ((response && response.data && response.data.id) ? response.data.id : null)
    # Self-proceed and commit the change request so the charge becomes WAIVED (not left pending in governance)
    * if (crId) karate.http(baseUrl + '/v1/change-requests/' + crId + '/proceed').header('Authorization', currentAuthHeader).post({})
    * if (crId) karate.http(baseUrl + '/v1/change-requests/' + crId + '/approve').header('Authorization', currentAuthHeader).post({ comment: 'Auto-approved waiver' })
    * if (crId) karate.http(baseUrl + '/v1/change-requests/' + crId + '/commit').header('Authorization', currentAuthHeader).post({})
