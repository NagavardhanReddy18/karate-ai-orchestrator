@loans @channel @e2e @data-driven @channel-personal-overdraft
Feature: Channel Personal Overdraft API — data-driven runner over all enabled Excel rows

  # ── Data-driven runner ────────────────────────────────────────────────────
  # Loads every row whose "run" column is "Y" from Channel-Personal-Overdraft-Automation.xlsx
  # and iterates through each scenario calling @lifecycle.
  Scenario: Run Channel Personal Overdraft Tests for all enabled Excel rows
    # 1. Authenticate once for the test run
    Given url baseUrl + '/auth/login'
    And header Content-Type = 'application/json'
    And request { username: 'admin', password: 'Password123' }
    When method post
    Then status 200
    * def globalAuthToken = response.token
    * karate.log('[18-CHANNEL-POD] Global admin authentication succeeded')

    # 2. Load Excel test data
    * def Loader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def loadRows =
    """
    function(paths) {
      for (var i = 0; i < paths.length; i++) {
        try {
          var rows = Loader.load(karate.toAbsolutePath('classpath:' + paths[i]));
          if (rows != null && rows.length > 0) {
            karate.log('[18-CHANNEL-POD] using', paths[i], '->', rows.length, 'row(s) with run=Y');
            return rows;
          }
        } catch (e) { karate.log('[18-CHANNEL-POD] could not read', paths[i], ':', e); }
      }
      return [];
    }
    """
    * def rawRows = loadRows(['features/loans/testdata/Channel-Personal-Overdraft-Automation.xlsx'])
    * def annotateRows = 
    """
    function(rList, token) {
      if (rList == null) return [];
      var n = rList.length;
      for (var i = 0; i < n; i++) {
        rList[i].rowIndex = i + 1;
        rList[i].totalRows = n;
        rList[i].authToken = token;
      }
      return rList;
    }
    """
    * def rows = annotateRows(rawRows, globalAuthToken)
    * def rowCount = rows.length
    * print '======================================================='
    * print '[18-CHANNEL-POD] Total Excel rows enabled (run=Y):', rowCount
    * print '======================================================='
    * if (rowCount == 0) karate.log('[18-CHANNEL-POD] No run=Y rows found — skipping')
    * if (rowCount > 0) karate.call('classpath:features/loans/18-BLO-Channel-Personal-Overdraft.feature@lifecycle', rows)

  @ignore @lifecycle
  Scenario: Execute Channel Personal Overdraft Request from Excel Row
    * def td = (typeof __arg !== 'undefined' && __arg != null) ? __arg : ((typeof row !== 'undefined' && row != null) ? row : {})
    * print '======================================================='
    * print '[18-CHANNEL-POD] Running Scenario [' + td.rowIndex + '/' + td.totalRows + ']:', td.scenarioId, '-', td.description
    * print '======================================================='

    * def authToken = td.authToken

    # 1. Build Channel Personal Overdraft Payload as JS Object
    * def uniqueChannelRef = td.channelRefPrefix + '-' + java.lang.System.currentTimeMillis()
    * def appPayload = ({})
    * appPayload.channelCode = td.channelCode
    * appPayload.channelRefNo = uniqueChannelRef
    * appPayload.customerId = td.customerId
    * appPayload.productTypeCode = td.productTypeCode
    * appPayload.productCode = td.productCode
    * appPayload.requestedLimit = td.requestedLimit
    * appPayload.loanCurrency = td.loanCurrency
    * appPayload.loanPurpose = td.loanPurpose
    * appPayload.odAccountChoice = td.odAccountChoice
    * appPayload.accountOpenBranch = td.accountOpenBranch
    * if (td.customerMarginInterest !== "" && td.customerMarginInterest != null) appPayload.customerMarginInterest = td.customerMarginInterest
    * appPayload.incomeItems = [{ type: td.incomeType, amount: td.incomeAmount, currency: td.loanCurrency, frequency: 'MONTHLY' }]
    * appPayload.expenseItems = [{ type: td.expenseType, amount: td.expenseAmount, currency: td.loanCurrency, frequency: 'MONTHLY' }]
    * appPayload.signedDocumentCodes = (td.docCode && td.docCode.length > 0) ? [td.docCode] : []

    # 2. Call ChannelApiHelper Java utility
    * def ChannelHelper = Java.type('com.ird.beyond.lo.test.util.ChannelApiHelper')
    * def targetUrl = baseUrl + '/v1/channel/personal-overdrafts'
    * def res = ChannelHelper.postMultipart(targetUrl, authToken, appPayload, td.docCode, td.docFileName)
    * def resStatus = res.status
    * def resBody = res.body

    * def expectedStatusNum = parseInt(td.expectedHttpStatus)
    * print '[18-CHANNEL-POD] Response Status:', resStatus, 'Expected:', expectedStatusNum
    * print '[18-CHANNEL-POD] Response Body:', resBody
    * match resStatus == expectedStatusNum

    # 3. For Successful Creations, Verify Returned Fields & Status Endpoint
    * if (expectedStatusNum == 201) karate.log('[18-CHANNEL-POD] Application created with ref:', resBody.applicationRef)
    * if (expectedStatusNum == 201 && (!resBody.applicationRef || resBody.status !== td.expectedAppStatus)) karate.fail('Application creation assertion failed: ' + JSON.stringify(resBody))
    * if (expectedStatusNum == 201 && (!resBody.debitInterestRate || !resBody.reviewDate || !resBody.limitExpiryDate)) karate.fail('Missing terms in 201 response: ' + JSON.stringify(resBody))
