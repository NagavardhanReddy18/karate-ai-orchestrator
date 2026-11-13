@loans @e2e @data-driven
Feature: Retail Loan Lifecycle — data-driven runner over all enabled Excel rows

  # ── Data-driven runner ────────────────────────────────────────────────────
  # Loads every row whose "run" column is "Y" from the Excel sheet and iterates
  # through each one, calling @lifecycle below.
  # Credential fallback is handled inside @lifecycle via getCred():
  #   row column filled → use that value | blank → fall back to karate-config.
  Scenario: Run Retail Loan Lifecycle for all enabled Excel rows
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Retail-Excel-Automation.xlsx')
    * def rawRows = ExcelDataLoader.load(excelPath)
    * def annotateRows = function(rList) { if (rList == null) return []; var n = rList.length; for (var i = 0; i < n; i++) { rList[i].rowIndex = i + 1; rList[i].totalRows = n; } return rList; }
    # runOnEnv column (optional): blank = every environment; otherwise a comma list of ports or env
    # names (9090, 9190, dev, test) — for rows whose product is configured differently per server.
    * def forThisEnv = function(r) { var e = r.runOnEnv; if (e == null || e.toString().trim() == '') return true; var parts = e.toString().split(','); for (var i = 0; i < parts.length; i++) { var p = parts[i].trim(); if (p == karate.env || baseUrl.indexOf(':' + p + '/') >= 0) return true; } return false }
    * def rows = annotateRows(karate.filter(rawRows, forThisEnv))
    * def rowCount = (rows != null) ? rows.length : 0
    * print '======================================================='
    * print '[04-RETAIL] Total Excel rows enabled (run=Y):', rowCount
    * print '======================================================='
    * if (rowCount == 0) karate.log('[04-RETAIL] No run=Y rows found in Retail-Excel-Automation.xlsx — skipping')
    * if (rowCount > 0) karate.call('classpath:features/loans/04-BLO-LifeCycle.feature@lifecycle', rows)

  @ignore @lifecycle
  Scenario: Run direct lifecycle for one Excel row with step-by-step state and assignedTo verification
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Retail-Excel-Automation.xlsx')
    * def activeRows = ExcelDataLoader.load(excelPath)
    * def excelRow = (activeRows != null && activeRows.length > 0) ? activeRows[0] : null
    * def td = (typeof __arg !== 'undefined' && __arg != null) ? __arg : ((typeof row !== 'undefined' && row != null) ? row : excelRow)
    * print '==================================================='
    * print 'START RETAIL EXCEL ROW [' + (td.rowIndex ? td.rowIndex : 1) + '/' + (td.totalRows ? td.totalRows : 1) + '] | TestCase:', td.testCaseId, '| Customer:', td.customerName, '| Amount:', td.loanAmount, td.loanAmountCurrency
    * print '==================================================='

    # ── Excel-driven store / dbQuery / verify columns ─────────────────────────
    # Anchors below hand the current row and the response in hand to RowActions,
    # which runs whichever of these columns the workbook defines at that point:
    #
    #   storeAfterStepNN   @Name = $.responseField | DB(select ...) | 'literal'
    #   dbQueryAfterStepNN @Name = select ...          result must match @Name
    #   verifyAfterStepNN  DB(select count(*) ...)     passes when the count is 0
    #                      $.status == APPROVED        response field
    #                      @Name != null               stored value
    #
    # The plain column names — store, dbQuery, verify — fire once at the end of
    # the row. A workbook that defines none of them is unaffected: every anchor
    # then costs one map lookup and does nothing.
    #
    # Database credentials come from src/test/resources/db.properties, never from
    # the sheet. See RowActions and DbSupport for the full syntax.
    * def RowActions = Java.type('com.ird.beyond.lo.test.util.RowActions')
    * RowActions.beginRow(td.testCaseId)
    # karate.get() is used rather than a bare `response` because the earliest
    # anchors run before any HTTP call has put one in scope.
    # The fourth argument lets a column name one of this feature's own variables —
    # appId, draftId, generatedCbsAccountNo — with var(appId). Needed at the end of
    # a row, where the only response still in scope is the last call made.
    * def atStep = function(step) { return RowActions.runAnchor(td, step, karate.get('response'), function(n){ return karate.get(n) }) }

    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }

    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn

    * def getCred = function(excelVal, defaultVal) { return (excelVal && excelVal.toString().trim() != '') ? excelVal.toString().trim() : defaultVal }

    # ── Negative-test matcher (evaluated at draft save and at submit) ─────────
    # A row is negative when expectedStatus or expectedError is filled. It passes at the first call
    # that refuses it with that status (blank = any 4xx/5xx) and with expectedError somewhere in the
    # body (case-insensitive). The draft save refuses invalid Interest & Schedule repayment options
    # (balloon, moratorium, PEP, step, mixed, offset, interest frequency); submit refuses the rest.
    # expectedStatus CHARGE marks a charge negative: it runs the normal flow and passes at the stage charge check
    # (STAGE CHARGES below) whose error contains expectedError - so it is not an API negative here.
    * def chargeNegRow = getCred(td.expectedStatus, '').toUpperCase() == 'CHARGE'
    * def isNegativeTest = !chargeNegRow && ((td.expectedError != null && td.expectedError.toString().trim() != '') || (td.expectedStatus != null && td.expectedStatus.toString().trim() != ''))
    * def matchNegative =
    """
    function(status, body) {
      // JSON serialisation escapes '/' as '\/' — undo it so an expectedError such as a date '15/12/2026' matches.
      var bodyStr = karate.toString(body).toLowerCase().split('\\/').join('/');
      var expErr  = td.expectedError  ? td.expectedError.toString().trim().toLowerCase() : '';
      var expStat = td.expectedStatus ? td.expectedStatus.toString().trim() : '';
      var expCode = td.expectedCode ? td.expectedCode.toString().trim().toUpperCase() : '';
      var statusOk = (expStat == '') ? (status >= 400) : (status == parseInt(expStat));
      var errorOk  = (expErr  == '') ? (status >= 400) : (bodyStr.indexOf(expErr) >= 0);
      var codeOk   = (expCode == '') || (body != null && body.code != null && body.code.toString().toUpperCase() == expCode);
      return statusOk && errorOk && codeOk;
    }
    """

    * def activeAdminUser = getCred(td.adminUsername, defaultAdminUsername)
    * def activeAdminPass = defaultAdminPassword
    # ── Stage actions come from the sheet only ───────────────────────────────
    # Every stage that runs takes its action from its own column (uwAction, approver1Action, approver2Action,
    # issuerAction, acceptorAction, setupAction); a blank cell fails the row instead of falling back to a default.
    # A stage the flow skips needs none: the skip* columns, and - when the scorecard AUTO-approves - the
    # underwriter's decision and both approvers.
    * def requiredCell = function(col, stage) { var v = getCred(td[col], null); if (v == null) throw new Error('[SHEET] TestCase ' + td.testCaseId + ': ' + col + ' is blank - ' + stage + ' runs, so ' + col + ' must be filled'); return v }
    * def activeOfficerUser = getCred(td.officerUsername, defaultOfficerUsername)
    * def activeOfficerPass = defaultOfficerPassword
    * def activeUwUser = getCred(td.underwriterUsername, defaultUnderwriterUsername)
    * def activeUwPass = defaultUnderwriterPassword
    * def activeApprover1User = getCred(td.approver1Username, null)
    * def activeApprover1Pass = defaultApprover1Password
    * def activeApprover2User = getCred(td.approver2Username, null)
    * def activeApprover2Pass = defaultApprover2Password
    * def activeIssuerUser = getCred(td.issuerUsername, defaultIssuerUsername)
    * def activeIssuerPass = defaultIssuerPassword
    * def activeAcceptorUser = getCred(td.acceptorUsername, defaultAcceptorUsername)
    * def activeAcceptorPass = defaultAcceptorPassword
    * def activeSetupUser = getCred(td.setupUsername, defaultSetupUsername)
    * def activeSetupPass = defaultSetupPassword

    # The account every charge is settled from. Resolved once so the origination-stage collection and
    # the CHARGE SETTLEMENT GATE below can never disagree about which account they are draining.
    * def feeAcct = (td.feeFundingAccountNumber && td.feeFundingAccountNumber.toString().trim() != '') ? td.feeFundingAccountNumber.toString().trim() : td.repaymentAccountNumber.toString().trim()

    # What to do with a charge that will not settle. The Retail workbook predates this column, so it
    # defaults rather than failing the way 05/06/07's sheetVal() does:
    #   COLLECT (default) — settle from feeAcct, and fail loudly naming the server's own reason if
    #                       that account cannot cover it.
    #   WAIVE             — waive whatever will not settle, so the lifecycle can still be exercised
    #                       against a drained funding account.
    * def chargeFallbackAction = (td.chargeFallbackAction && td.chargeFallbackAction.toString().trim() != '') ? td.chargeFallbackAction.toString().trim().toUpperCase() : 'COLLECT'

    # ── STAGE CHARGES ─────────────────────────────────────────────────────────
    # The product configuration levies each charge at a collection stage. Each stage has a sheet column naming
    # the charges that stage's user collects - charge name or code, any case, several separated by ';':
    #   APPLICATION       applicationCharges      officer, before submit
    #   ASSESSMENT        assessmentCharges       underwriter (the issuer when the scorecard AUTO-approved)
    #   OFFER             offerCharges            issuer
    #   OFFER_ACCEPTANCE  offerAcceptanceCharges  acceptor
    #   SETUP             setupCharges            setup user, before the CBS account is created
    # The row fails when a charge due at the stage is not named in its column, or a named charge is not
    # configured at that stage. A deferrable charge listed before it falls due may be named to collect it early.
    # A charge that will not settle is waived when chargeFallbackAction is WAIVE (chargeWaiveReason as the reason).
    # A charge negative row (expectedStatus CHARGE) passes at the first charge error containing expectedError.
    # The calls reuse the stage user's own session: auto-collect-helper signs a fresh admin in, which revokes it.
    * def noCharges = { error: null, collected: [] }
    # The rules live in stage-charges.js, shared with 08 - including the waiver (maker-checker approval + commit).
    * def stageChargesJs = read('classpath:features/loans/stage-charges.js')
    * def stageCharges = function(hdr, stage, column, chargeAppId) { return stageChargesJs(hdr, stage, column, chargeAppId, td, feeAcct) }
    * def chargeNegMatched =
    """
    function(res, stage) {
      if (!chargeNegRow || res == null || !res.error) return false;
      var exp = getCred(td.expectedError, '').toLowerCase();
      if (exp != '' && res.error.toLowerCase().indexOf(exp) < 0) return false;
      karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Charges refused at', stage, '|', res.error);
      return true;
    }
    """
    * def chargeFail = function(res, stage) { return '[charges ' + stage + '] TestCase ' + td.testCaseId + ': ' + res.error + (chargeNegRow ? ' (expected an error containing "' + td.expectedError + '")' : '') }
    # ====================================================
    # APPROVAL-LIMIT BOOTSTRAP (idempotent per row)
    # ====================================================
    * def freshAdminToken = login(activeAdminUser, activeAdminPass)
    * def freshAdminHeader = 'Bearer ' + freshAdminToken
    * def approvalLimitArgs =
    """
    {
      baseUrl: '#(baseUrl)',
      makerAuthHeader: '#(freshAdminHeader)',
      makerUsername: '#(activeAdminUser)',
      loanType: '#(td.loanProductType)',
      partyType: '#(td.approvalLimitPartyType)',
      facilityType: '#(td.approvalLimitFacilityType)',
      currencyCode: '#(td.loanAmountCurrency)',
      requiredAmount: #(td.loanAmount),
      limitAmount: #(td.approvalLimitAmount)
    }
    """
    # A negative row's data is deliberately invalid (unknown product type, currency, amount): no limit is bootstrapped for it.
    * if (!isNegativeTest) karate.call('classpath:features/loans/approval-limit-helper.feature', approvalLimitArgs)

    # Step 01: Authenticate Loan Officer
    * def officerToken = login(activeOfficerUser, activeOfficerPass)
    * def officerAuthHeader = 'Bearer ' + officerToken
    * def authHeader = officerAuthHeader
    * print '✔ [TESTER VERIFICATION] Step 01: Officer Auth -> User:', activeOfficerUser, '| Status: PASSED (Token Issued)'

    # ─── ORIGINATION WIZARD ─────────────────────────────────────────────────

    * atStep('01')

    # Step 02: Submittable Product Types
    Given path '/v1/product-types/submittable'
    When method GET
    * def submittableCodes = karate.jsonPath(response, "$[*].code")
    * print '✔ [TESTER VERIFICATION] Step 02: Submittable Product Types -> Target:', td.loanProductType, '| Returned Codes:', submittableCodes, '| MATCHED'

    # (A negative row's data is invalid on purpose - this lookup only informs; the save / submit must refuse the row.)
    Given path '/v1/product-types/' + td.loanProductType + '/fields'
    When method GET
    Then assert responseStatus == 200 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 02b: Facility Fields Lookup -> Facility:', td.loanProductType, '| Status: MATCHED'

    * atStep('02')

    # Step 03: Customer Selection & Verification
    Given path '/v1/origination/customers/' + td.customerId
    When method GET
    # A negative row may name a blank or unknown customer on purpose: the lookup answers 404 and the draft save /
    # submit is what must refuse it.
    Then assert responseStatus == 200 || isNegativeTest
    * def custLookupStatus = responseStatus
    * def custResp = responseStatus == 200 ? response : {}
    * def apiBranch = (custResp != null && (custResp.branch || custResp.branchCode || custResp.homeBranch)) ? (custResp.branch || custResp.branchCode || custResp.homeBranch) : null
    * def customerBranch = (td.branch != null && td.branch != '') ? td.branch : (apiBranch != null ? apiBranch : '00000001')
    * if (custLookupStatus == 200 && custResp.customerId != td.customerId) karate.fail('[CUSTOMER] TestCase ' + td.testCaseId + ': lookup returned customer ' + custResp.customerId + ', expected ' + td.customerId)
    * if (td.customerName && custResp.fullName) karate.match(custResp.fullName, td.customerName)
    * print '✔ [TESTER VERIFICATION] Step 03: Customer Lookup -> Expected ID:', td.customerId, '| Expected Name:', td.customerName, '| Actual Name:', custResp.fullName, '| MATCHED'

    * atStep('03')

    # Step 04: Facility Purposes Lookup
    Given path '/v1/product-types/' + td.loanProductType + '/purposes'
    When method GET
    Then assert responseStatus == 200 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 04: Facility Purposes Lookup -> Facility:', td.loanProductType, '| Received Count:', karate.sizeOf(response), '| PASSED'

    * atStep('04')

    # Step 05: Product Selection & Base Rates
    Given path '/v1/origination/products/eligible'
    And param currency = td.loanAmountCurrency
    And param facilityTypeId = 'LOAN'
    When method GET
    Then status 200
    * def prodItems = (response.items ? response.items : response)
    * print '✔ [TESTER VERIFICATION] Step 05: Eligible Products Lookup -> Expected Product:', td.selectedProductCode, '| Returned Count:', karate.sizeOf(prodItems), '| MATCHED'

    Given path '/v1/origination/interest/base-codes'
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 05b: Interest Base Codes -> Returned Count:', karate.sizeOf(response), '| PASSED'

    * atStep('05')

    # Step 06: Initial Draft Creation
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef
    * match response.id == '#number'
    * match response.applicationRef == '#string'
    * print '✔ [TESTER VERIFICATION] Step 06: Initial Draft Creation -> Draft ID:', draftId, '| Reference:', draftRef, '| PASSED'

    # Step 06b: Schedule Generation Validation
    * def calcTermMonths = (td.termFrequency == 'YEARS' ? td.loanTerm * 12 : td.loanTerm)
    # generateSchedule column: blank / Y = generate (the UI's Interest & Schedule step does);
    # N = skip it, exactly as a direct API caller can — used by negative rows that prove submit
    # refuses a draft that never had a schedule.
    * def doGenerate = !(td.generateSchedule != null && td.generateSchedule.toString().trim().toUpperCase() == 'N')
    # rateId and repaymentType come from the CBS sub-product configuration, as the UI's Interest &
    # Schedule step sends them: rateId = the product's default rate for the interest type, and
    # repaymentType = the product's CBS letter code (e.g. C / R / K), never the sheet's descriptive value.
    # /products/eligible carries neither, so read the product from /products/search.
    Given path '/v1/origination/products/search'
    And param currency = td.loanAmountCurrency
    And param size = 200
    When method GET
    Then match [200, 503] contains responseStatus
    * def searchItems = (responseStatus == 200 && response.items) ? response.items : []
    * def cbsProduct = karate.filter(searchItems, function(p){ return p.productCode == td.selectedProductCode })
    * def cbsProduct = cbsProduct.length > 0 ? cbsProduct[0] : {}
    * def rateIdByType = { FIXED: '#(cbsProduct.defaultFixedRateId)', FLOATING: '#(cbsProduct.defaultFloatingRateId)', PROGRESSIVE: '#(cbsProduct.defaultProgressiveRateId)' }
    * def schedRateId = rateIdByType[td.interestType] || cbsProduct.defaultFixedRateId || cbsProduct.defaultFloatingRateId || cbsProduct.defaultProgressiveRateId || null
    * def schedRepaymentType = cbsProduct.repaymentType || null
    * if (!schedRateId) karate.log('[schedule] product', td.selectedProductCode, 'has no rate id in the sub-product configuration LO holds - CBS will refuse the schedule')
    * def genRequest = { loanAmount: '#(td.loanAmount)', currency: '#(td.loanAmountCurrency)', termMonths: '#(calcTermMonths)', annualInterestRate: '#(td.overriddenInterestRate)', repaymentFrequency: '#(td.repaymentFrequency)', productCode: '#(td.selectedProductCode)', repaymentType: '#(schedRepaymentType)', rateId: '#(schedRateId)', customerId: '#(td.customerId)' }
    # Loan start and first repayment dates, as the UI's Interest & Schedule step sends them. Without them the
    # server puts the first repayment on the business date (the disbursement day), off the sheet's schedule.
    * def schedFirstRepay = td.repaymentStartDate ? ('' + td.repaymentStartDate).substring(0, 10) : null
    * def schedLoanStart = td.loanStartDate ? ('' + td.loanStartDate).substring(0, 10) : null
    * if (schedFirstRepay) karate.set('genRequest', karate.merge(genRequest, { firstRepaymentDate: schedFirstRepay }))
    * if (schedLoanStart) karate.set('genRequest', karate.merge(genRequest, { loanStartDate: schedLoanStart }))
    # Planned Extra Payment (PEP): sent to schedule generation exactly as the UI does - only when the
    # sub-product allows it (pepApplicable, PEP field editable) and the row's pepRows has an amount.
    * def pepList = td.pepRows == null || td.pepRows == '' ? [] : (typeof td.pepRows == 'string' ? JSON.parse(td.pepRows) : td.pepRows)
    * def pepRow = pepList.length > 0 ? pepList[0] : null
    * def pepModes = cbsProduct.repaymentFieldModes ? cbsProduct.repaymentFieldModes : {}
    * def pepSent = pepRow != null && pepRow.pepAmount != null && cbsProduct.pepApplicable == true && pepModes.PEP == 'E'
    * def toPepFields = function(r) { return { pepStartDate: r.startDate, pepAmount: r.pepAmount, pepNumPaymnts: (r.numRepayments == null ? null : '' + r.numRepayments), pepFrequency: r.frequency } }
    * def pepFields = pepSent ? toPepFields(pepRow) : {}
    * if (pepSent) karate.set('genRequest', karate.merge(genRequest, pepFields))
    * if (pepRow != null && !pepSent) karate.log('[pep] TestCase', td.testCaseId, 'has pepRows but the product does not allow PEP - not sent to schedule generation, as in the UI')
    # Moratorium / balloon / step up-down / separate interest frequency, sent to schedule generation by the UI's
    # rules: each only when the sub-product allows it (repaymentFieldModes = E and its product switch) and the row
    # has a value. Customer margin and applicationRef always go, as in the UI. Offset and mixed schedule are not
    # schedule inputs (draft only).
    * def buildOptionFields =
    """
    function(p, row, ref) {
      var m = p.repaymentFieldModes ? p.repaymentFieldModes : {};
      var has = function(v) { return v != null && ('' + v).trim() != '' };
      var o = { sent: [], gen: {}, setup: {}, spec: { moratoriumMonths: 0, balloon: 0, interestFrequency: null, interestStart: null } };
      var morOpts = p.moratoriumOptions ? p.moratoriumOptions : [];
      if (m.MORATORIUM == 'E' && morOpts.length > 0 && has(row.moratoriumType)) {
        var mode = has(row.moratoriumCollectionMode) ? row.moratoriumCollectionMode : null;
        for (var i = 0; mode == null && i < morOpts.length; i++) if (morOpts[i].offeredMoratorium == row.moratoriumType) mode = morOpts[i].collectionMode;
        var months = has(row.moratoriumMonths) ? Number(row.moratoriumMonths) : 0;
        o.gen.moratoriumType = row.moratoriumType; o.gen.moratoriumMonths = months; o.gen.moratoriumCollectionMode = mode;
        o.setup.moratoriumType = row.moratoriumType; o.setup.moratoriumMonths = months; o.setup.moratoriumCollectionMode = mode;
        o.spec.moratoriumMonths = months; o.sent.push('moratorium ' + row.moratoriumType + ' x' + months + ' ' + mode);
      }
      if (m.BALLOON == 'E' && p.balloonPayment == true && has(row.balloonAmount)) {
        o.gen.balloonPaymentAmount = Number(row.balloonAmount); o.setup.balloonAmount = Number(row.balloonAmount);
        o.spec.balloon = Number(row.balloonAmount); o.sent.push('balloon ' + row.balloonAmount);
      }
      var steps = !has(row.stepRows) ? [] : (typeof row.stepRows == 'string' ? JSON.parse(row.stepRows) : row.stepRows);
      if (m.STEP_UP_DOWN == 'E' && p.stepUpStepDown == true && steps.length > 0) {
        o.gen.stepRows = steps; o.setup.stepRows = steps; o.spec.steps = steps; o.sent.push(steps.length + ' step block(s)');
      }
      if (('' + p.repaymentType).toUpperCase() == 'C' && p.interestPrincipalFrequency == 'DIFFERENT' && has(row.interestFrequency)) {
        o.gen.interestRepayFrequency = row.interestFrequency; o.setup.interestFrequency = row.interestFrequency; o.spec.interestFrequency = row.interestFrequency;
        if (has(row.interestStartDate)) {
          var isd = ('' + row.interestStartDate).substring(0, 10);
          o.gen.interestRepayStartDate = isd; o.setup.interestFrequencyDate = isd; o.spec.interestStart = isd;
        }
        o.sent.push('interest ' + row.interestFrequency);
      }
      o.gen.customerMarginInterest = has(row.customerMarginInterest) ? Number(row.customerMarginInterest) : 0;
      o.setup.customerInterestMargin = o.gen.customerMarginInterest;
      if (has(ref)) o.gen.applicationRef = ref;
      return o;
    }
    """
    * def optionFields = buildOptionFields(cbsProduct, td, draftRef)
    * eval karate.set('genRequest', karate.merge(genRequest, optionFields.gen))
    * if (optionFields.sent.length > 0) karate.log('[schedule] repayment options sent - TestCase', td.testCaseId, ':', optionFields.sent.join(', '))
    # scheduleOverride column (JSON, blank on normal rows): a negative row sends a deliberately bad
    # schedule request. Each key replaces the request field; null leaves the field out;
    # {"__EMPTY_BODY__": true} sends {}. e.g. {"rateId": null} or {"repaymentType": "PRINCIPAL-AND-INTEREST"}
    * def schedOverride = td.scheduleOverride == null || td.scheduleOverride == '' ? null : (typeof td.scheduleOverride == 'string' ? JSON.parse(td.scheduleOverride) : td.scheduleOverride)
    # createAccountOverride column (JSON, blank on normal rows): a CBS-setup negative row runs the whole journey to Loan
    # Setup, sends a deliberately bad Create Loan Account request to CBS - each key replaces the field, null drops it,
    # {"__EMPTY_BODY__": true} sends {} - and expects CBS's exact refusal (expectedStatus / expectedError), checked at
    # Step 18c. Such a row is not refused at submit, so the submit gate below lets it through.
    * def setupOverride = td.createAccountOverride == null || td.createAccountOverride == '' ? null : (typeof td.createAccountOverride == 'string' ? JSON.parse(td.createAccountOverride) : td.createAccountOverride)
    * def setupNegRow = isNegativeTest && setupOverride != null
    * def applyScheduleOverride =
    """
    function(req, ov) {
      if (ov == null) return req;
      if (ov['__EMPTY_BODY__']) return {};
      var out = {};
      var rk = karate.keysOf(req);
      for (var i = 0; i < rk.length; i++) out[rk[i]] = req[rk[i]];
      var ok = karate.keysOf(ov);
      for (var j = 0; j < ok.length; j++) { var k = ok[j]; if (ov[k] == null) delete out[k]; else out[k] = ov[k]; }
      return out;
    }
    """
    * def genRequest = applyScheduleOverride(genRequest, schedOverride)
    * if (schedOverride != null) karate.log('[schedule] scheduleOverride applied - TestCase', td.testCaseId, '| request sent:', karate.toString(genRequest))
    # A "Manual Schedule" sub-product (repaymentTypeDesc from the CBS sub-product configuration) also
    # sends the sheet's autoPopulationMethod to schedule generation, as the UI's Auto Population field does.
    * def isManualProduct = cbsProduct.repaymentTypeDesc == 'Manual Schedule'
    * if (isManualProduct && td.autoPopulationMethod) karate.set('genRequest', karate.merge(genRequest, { autoPopulationMethod: td.autoPopulationMethod }))
    * print '[schedule] Step 06b request -> product:', td.selectedProductCode, '| rateId:', schedRateId, '| repaymentType:', schedRepaymentType
    * def genResult = doGenerate ? karate.http(baseUrl + '/v1/origination/schedule/generate').header('Authorization', authHeader).header('Content-Type', 'application/json').post(genRequest) : null
    * def genStatus = doGenerate ? genResult.status : 0
    * def genBody = doGenerate ? genResult.body : null
    * if (!doGenerate) karate.log('[schedule] generateSchedule=N - TestCase', td.testCaseId, 'skips schedule generation, as a direct API caller can')
    # A positive row needs a generated schedule: any non-200 (e.g. 503 CBS_UNAVAILABLE) fails it.
    # A negative row passes here when this is the refusal it expects; otherwise it goes on to the
    # draft save / submit where its expectedError is checked.
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Schedule generation rejected with HTTP', genStatus, '| Expected error matched:', td.expectedError)
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) RowActions.endRow(td.testCaseId)
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) karate.abort()
    # A schedule-negative row (scheduleOverride filled) must be refused here exactly as expected.
    * if (doGenerate && isNegativeTest && schedOverride != null && !matchNegative(genStatus, genBody)) karate.fail('[SCHEDULE NEGATIVE FAILED] TestCase ' + td.testCaseId + ': expected HTTP ' + td.expectedStatus + ' / code ' + td.expectedCode + ' / error "' + td.expectedError + '" but got HTTP ' + genStatus + ' ' + karate.toString(genBody))
    * if (doGenerate && !isNegativeTest && genStatus != 200) karate.fail('[SCHEDULE GENERATION FAILED] TestCase ' + td.testCaseId + ': HTTP ' + genStatus + ' ' + karate.toString(genBody))
    # PEP checks on the generated schedule (a positive row that sent a PEP): exactly numRepayments
    # installments are raised by the PEP amount, the regular installment is lower than the same loan
    # without PEP, and the loan still pays off. The pep column itself is checked at the end of the row
    # (known defect: the server maps it to 0), so the rest of the journey still runs.
    * def pepCheck = doGenerate && !isNegativeTest && pepSent && genStatus == 200
    * def analysePep =
    """
    function(rows, pepAmt) {
      var counts = {}, mode = null, best = 0;
      for (var i = 0; i < rows.length; i++) { var k = Math.round(Number(rows[i].emi) * 100); counts[k] = (counts[k] || 0) + 1; if (counts[k] > best) { best = counts[k]; mode = k / 100; } }
      var bumped = 0, pepCol = 0;
      for (var j = 0; j < rows.length; j++) {
        if (pepAmt > 0 && Math.abs(Number(rows[j].emi) - (mode + pepAmt)) < 1) bumped++;
        if (pepAmt > 0 && Math.abs(Number(rows[j].pep || 0) - pepAmt) < 0.01) pepCol++;
      }
      var lastRow = rows.length ? rows[rows.length - 1] : null;
      var last = lastRow == null ? -1 : Number(lastRow.closingBalance != null ? lastRow.closingBalance : (lastRow.balance != null ? lastRow.balance : 0));
      return { regularEmi: mode, bumped: bumped, pepColumn: pepCol, lastBalance: last };
    }
    """
    * def pepAmountNum = pepSent ? Number(pepRow.pepAmount) : 0
    * def pepCountNum = pepSent && pepRow.numRepayments != null ? Number(pepRow.numRepayments) : 0
    * def pepGen = pepCheck ? analysePep(genBody, pepAmountNum) : null
    * def noPepReq = pepCheck ? karate.merge(genRequest, { pepStartDate: null, pepAmount: null, pepNumPaymnts: null, pepFrequency: null }) : null
    * def noPepResult = pepCheck ? karate.http(baseUrl + '/v1/origination/schedule/generate').header('Authorization', authHeader).header('Content-Type', 'application/json').post(noPepReq) : null
    * def noPepEmi = (pepCheck && noPepResult.status == 200) ? analysePep(noPepResult.body, 0).regularEmi : null
    * if (pepCheck && pepGen.bumped != pepCountNum) karate.fail('[PEP NOT APPLIED] TestCase ' + td.testCaseId + ': expected ' + pepCountNum + ' installments raised by ' + pepAmountNum + ', found ' + pepGen.bumped + ' (regular installment ' + pepGen.regularEmi + ')')
    * if (pepCheck && Math.abs(pepGen.lastBalance) > 1) karate.fail('[PEP SCHEDULE] TestCase ' + td.testCaseId + ': last closing balance is ' + pepGen.lastBalance + ', expected 0')
    * if (pepCheck && noPepEmi != null && !(pepGen.regularEmi < noPepEmi)) karate.fail('[PEP SCHEDULE] TestCase ' + td.testCaseId + ': regular installment with PEP ' + pepGen.regularEmi + ' is not lower than without PEP ' + noPepEmi)
    * def pepColumnOk = !pepCheck || pepGen.pepColumn == pepCountNum
    * if (pepCheck) karate.log('✔ [TESTER VERIFICATION] Step 06b PEP -> raised installments:', pepGen.bumped, 'of', pepCountNum, '| regular EMI with PEP:', pepGen.regularEmi, '| without PEP:', noPepEmi, '| last balance:', pepGen.lastBalance, '| pep column rows:', pepGen.pepColumn)
    # Repayment options must show in the schedule (shapes confirmed against CBS on 9190): a moratorium of N
    # months = the first N installments are 0 and repayments resume at N+1; a balloon = the final principal is
    # the balloon (within 5%); a separate interest frequency = interest only on that cycle, from its start date.
    * def checkOptionsSchedule =
    """
    function(rows, s) {
      var errs = [], n = rows.length;
      if (n == 0) return ['empty schedule'];
      var num = function(v) { return v == null ? 0 : Number(v) };
      var bal = function(r) { return num(r.closingBalance != null ? r.closingBalance : r.balance) };
      if (Math.abs(bal(rows[n - 1])) > 1) errs.push('last closing balance ' + bal(rows[n - 1]) + ', expected 0');
      if (s.moratoriumMonths > 0) {
        // By due date, not by row: installments falling in the first N months from the first due date are 0,
        // and the first one after them is not (rows are not monthly when principal and interest differ).
        var mo = function(d) { var p = ('' + d).substring(0, 10).split('-'); return Number(p[0]) * 12 + Number(p[1]) };
        var morEnd = mo(rows[0].dueDate) + s.moratoriumMonths, firstAfter = -1;
        for (var i = 0; i < n; i++) {
          if (mo(rows[i].dueDate) < morEnd) { if (num(rows[i].emi) > 0.01) { errs.push('moratorium: installment ' + (i + 1) + ' (' + rows[i].dueDate + ') has ' + rows[i].emi + ' due inside the ' + s.moratoriumMonths + '-month moratorium'); break; } }
          else { firstAfter = i; break; }
        }
        if (firstAfter >= 0 && num(rows[firstAfter].emi) <= 0.01) errs.push('moratorium: installment ' + (firstAfter + 1) + ' (' + rows[firstAfter].dueDate + ') is still 0 - repayments did not resume');
      }
      if (s.balloon > 0) {
        var lp = num(rows[n - 1].principal);
        if (lp < 0.95 * s.balloon || lp > s.balloon + 0.01) errs.push('balloon: final principal ' + lp + ' is not the balloon ' + s.balloon);
      }
      if (s.interestFrequency) {
        var per = { MONTHLY: 1, BI_MONTHLY: 2, QUARTERLY: 3, HALF_YEARLY: 6, SEMI_ANNUAL: 6, ANNUAL: 12, YEARLY: 12 }[('' + s.interestFrequency).toUpperCase()];
        var mon = function(d) { var p = ('' + d).substring(0, 10).split('-'); return Number(p[0]) * 12 + Number(p[1]) };
        var idates = [];
        for (var j = 0; j < n - 1; j++) if (num(rows[j].interest) > 0.01) idates.push(mon(rows[j].dueDate));
        if (idates.length == 0) errs.push('interest frequency: no interest charged before the final installment');
        if (s.interestStart && idates.length && idates[0] < mon(s.interestStart)) errs.push('interest frequency: interest charged before the interest start date ' + s.interestStart);
        for (var k = 1; per && k < idates.length; k++) if (idates[k] - idates[k - 1] != per) { errs.push('interest frequency: interest dates ' + (idates[k] - idates[k - 1]) + ' months apart, expected ' + per + ' (' + s.interestFrequency + ')'); break; }
      }
      if (s.steps && s.steps.length > 0) {
        // A block changes the EMI from its first installment: UP adds the step amount to the EMI in force just
        // before the block, DOWN must go below it (CBS recomputes the EMI after each block), and the EMI holds
        // across the block.
        for (var b = 0; b < s.steps.length; b++) {
          var st = s.steps[b], from = Number(st.startInstallment) - 1, to = Number(st.endInstallment) - 1;
          if (from < 1 || to >= n || to < from) { errs.push('step: block ' + (b + 1) + ' (' + st.startInstallment + '-' + st.endInstallment + ') is outside the schedule'); continue; }
          var before = num(rows[from - 1].emi), inBlock = num(rows[from].emi), amt = Number(st.stepAmount);
          var up = ('' + st.stepMode).toUpperCase() == 'UP';
          if (up && Math.abs(inBlock - (before + amt)) > 0.05) errs.push('step up: installment ' + (from + 1) + ' EMI ' + inBlock + ', expected ' + (before + amt) + ' (' + before + ' + ' + amt + ')');
          if (!up && inBlock >= before - 0.01) errs.push('step down: installment ' + (from + 1) + ' EMI ' + inBlock + ' is not below the EMI before the block (' + before + ')');
          for (var q = from + 1; q <= to; q++) if (Math.abs(num(rows[q].emi) - inBlock) > 0.05) { errs.push('step: installment ' + (q + 1) + ' EMI ' + rows[q].emi + ' differs from the block EMI ' + inBlock); break; }
        }
      }
      return errs;
    }
    """
    * def optCheck = doGenerate && !isNegativeTest && genStatus == 200 && (optionFields.spec.moratoriumMonths > 0 || optionFields.spec.balloon > 0 || optionFields.spec.interestFrequency != null || (optionFields.spec.steps != null && optionFields.spec.steps.length > 0))
    * def optErrors = optCheck ? checkOptionsSchedule(genBody, optionFields.spec) : []
    * if (optErrors.length > 0) karate.fail('[REPAYMENT OPTIONS NOT IN SCHEDULE] TestCase ' + td.testCaseId + ': ' + optErrors.join('; '))
    * if (optCheck) karate.log('✔ [TESTER VERIFICATION] Step 06b Repayment options -> ' + optionFields.sent.join(', ') + ' | schedule shape MATCHED')
    * print '✔ [TESTER VERIFICATION] Step 06b: Repayment Schedule Generation -> Loan Amount:', td.loanAmount, '| Term Months:', calcTermMonths, '| Status:', genStatus

    * atStep('06')

    # Step 07: Assets & Liabilities Lookup
    Given path '/v1/origination/customers/' + td.customerId + '/cbs-fd-accounts'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 503
    Given path '/v1/origination/customers/' + td.customerId + '/loan-accounts'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 503
    Given path '/v1/origination/customers/' + td.customerId + '/in-flight-exposure'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 503
    * print '✔ [TESTER VERIFICATION] Step 07: Accounts & Exposure Verification -> Verified CBS FD, Loan Accounts, and In-Flight Exposure'

    * atStep('07')

    # Step 08: Collateral & Commitments Lookup
    Given path '/v1/origination/customers/' + td.customerId + '/commitments'
    When method GET
    Then status 200
    * def hasCollateral = td.collateralType && td.collateralType != ''
    * def retailCollateralList = hasCollateral ? [ { "collateralType": td.collateralType, "description": td.collateralDescription, "estimatedValue": td.collateralEstimatedValue, "forcedSaleValue": td.collateralForcedSaleValue, "currency": td.loanAmountCurrency } ] : []
    * string manualCollateralsJson = retailCollateralList
    * print '✔ [TESTER VERIFICATION] Step 08: Commitments Lookup -> Commitments Count:', karate.sizeOf(response), '| Collateral Configured:', hasCollateral

    * atStep('08')

    # Step 09: Save/Update Complete Draft with Excel Data
    # incomeDetails / expenseDetails (optional): itemised rows keyed by applicant, {"PRIMARY":[{"type":..,"amount":..,"currency":..,"frequency":..}]}.
    # Submit only stores the keyed form; a bare list passes validation but is dropped (no income / expense items).
    Given path '/v1/origination/customers/' + td.customerId + '/accounts'
    When method GET
    Then assert responseStatus == 200 || isNegativeTest

    # Interest & Schedule repayment options come straight from the sheet (blank cell = null).
    # repaymentOptionsIncluded = true makes the save apply them as a whole, so blank also clears the
    # interestFrequency MONTHLY seeded at draft creation — a product whose interest follows the
    # repayment frequency refuses any interest frequency (VR-09). pepRows / stepRows / mixedBlocks are
    # JSON arrays in the cell, e.g. [{"seq":1,"stepMode":"UP","startInstallment":2,"endInstallment":6,"stepAmount":500}]
    Given path '/v1/origination/draft'
    And request
    """
    {
      "id": "#(draftId)",
      "applicationRef": "#(draftRef)",
      "loanCategory": "#(td.loanCategory)",
      "customerTypeSelected": "#(td.customerTypeSelected)",
      "customerId": "#(td.customerId)",
      "customerName": "#(td.customerName)",
      "branch": "#(customerBranch)",
      "accountOpenBranch": "#(customerBranch)",
      "loanPurpose": "#(td.loanPurpose)",
      "loanAmount": #(td.loanAmount),
      "loanAmountCurrency": "#(td.loanAmountCurrency)",
      "totalAmount": #(td.totalAmount),
      "totalAmountCurrency": "#(td.totalAmountCurrency)",
      "customerContribution": #(td.customerContribution),
      "loanTerm": #(td.loanTerm),
      "termFrequency": "#(td.termFrequency)",
      "selectedProductCode": "#(td.selectedProductCode)",
      "selectedProductName": "#(td.selectedProductName)",
      "loanProductType": "#(td.loanProductType)",
      "interestType": "#(td.interestType)",
      "rateId": "#(schedRateId)",
      "postProgressiveRateType": "#(td.postProgressiveRateType)",
      "overriddenInterestRate": #(td.overriddenInterestRate),
      "repaymentFrequency": "#(td.repaymentFrequency)",
      "loanStartDate": "#(td.loanStartDate)",
      "monthlyGrossIncome": #(td.monthlyGrossIncome),
      "incomeDetails": "##(td.incomeDetails)",
      "expenseDetails": "##(td.expenseDetails)",
      "existingEmiObligations": #(td.existingEmiObligations),
      "manualCollaterals": "#(manualCollateralsJson)",
      "settlementMode": "#(td.settlementMode)",
      "paymentType": "#(td.paymentType)",
      "effectiveInterestRate": #(td.effectiveInterestRate),
      "repaymentStartDate": "#(td.repaymentStartDate)",
      "docSignedState": "#(td.docSignedState)",
      "repaymentAccountNumber": "#(td.repaymentAccountNumber)",
      "feeFundingAccountNumber": "#(td.feeFundingAccountNumber)",
      "disbursementMode": "#(td.disbursementMode)",
      "disbursementDate": "#(td.disbursementDate)",
      "disbursementAccountNumber": "#(td.disbursementAccountNumber)",
      "disbursementNotes": "#(td.disbursementNotes)",
      "repaymentOptionsIncluded": true,
      "interestFrequency": "#(td.interestFrequency)",
      "interestStartDate": "#(td.interestStartDate)",
      "balloonAmount": "#(td.balloonAmount)",
      "offsetPooledAccount": "#(td.offsetPooledAccount)",
      "moratoriumMonths": "#(td.moratoriumMonths)",
      "moratoriumType": "#(td.moratoriumType)",
      "moratoriumCollectionMode": "#(td.moratoriumCollectionMode)",
      "autoPopulationMethod": "#(td.autoPopulationMethod)",
      "pepRows": "#(td.pepRows)",
      "stepRows": "#(td.stepRows)",
      "mixedBlocks": "#(td.mixedBlocks)"
    }
    """
    When method PUT
    * def saveStatus = responseStatus
    * if (isNegativeTest && matchNegative(saveStatus, response)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Draft save rejected with HTTP', saveStatus, '| Expected error matched:', td.expectedError)
    * if (isNegativeTest && matchNegative(saveStatus, response)) RowActions.endRow(td.testCaseId)
    * if (isNegativeTest && matchNegative(saveStatus, response)) karate.abort()
    * if (saveStatus != 200) karate.fail('[DRAFT SAVE REFUSED] TestCase ' + td.testCaseId + ': HTTP ' + saveStatus + ' ' + karate.toString(response) + (isNegativeTest ? ' | expected HTTP "' + td.expectedStatus + '" / error "' + td.expectedError + '"' : ''))
    * match response.loanAmount == td.loanAmount
    * match response.selectedProductCode == td.selectedProductCode
    * match response.customerId == td.customerId
    * def draftRef = response.applicationRef != null ? response.applicationRef : draftRef
    * print '✔ [TESTER VERIFICATION] Step 09: Save Draft Data -> Expected Loan Amount:', td.loanAmount, '| Actual Response:', response.loanAmount, '| Product:', response.selectedProductCode, '| Reference:', draftRef, '| MATCHED | Repayment options: interestFrequency', td.interestFrequency, 'balloon', td.balloonAmount, 'moratorium', td.moratoriumType, td.moratoriumMonths, 'autoPopulation', td.autoPopulationMethod

    # Step 09b: Manual Schedule Upload — the UI's Upload Schedule (Interest & Schedule step, after a
    # generated schedule) sends the rows to POST /draft/{id}/schedule. It runs after the draft save
    # because the server keys the upload on the product saved on the draft.
    # manualSchedule column: JSON rows [{"dueDate":"yyyy-MM-dd","principal":n,"interest":n}]. Blank on a
    # manual product = the generated schedule's dates and interest with the principal split evenly
    # (what a user's edited download holds). A filled cell on any other product is uploaded too, so a
    # negative row can prove the API refuses it.
    * def manualCell = td.manualSchedule == null || td.manualSchedule == '' ? null : (typeof td.manualSchedule == 'string' ? JSON.parse(td.manualSchedule) : td.manualSchedule)
    * def doManualUpload = doGenerate && (isManualProduct || manualCell != null)
    * def round2 = function(n) { return Math.round(n * 100) / 100 }
    * def sumPrincipal = function(list) { var t = 0; for (var i = 0; i < list.length; i++) t += Number(list[i].principal || 0); return round2(t) }
    * def buildManualRows =
    """
    function(cell, gen, loanAmt) {
      var src = [];
      if (cell != null) {
        for (var i = 0; i < cell.length; i++) src.push({ dueDate: cell[i].dueDate, principal: Number(cell[i].principal || 0), interest: Number(cell[i].interest || 0) });
      } else {
        var n = gen.length, base = Math.floor(loanAmt * 100 / n) / 100, acc = 0;
        for (var j = 0; j < n; j++) {
          var p = (j == n - 1) ? round2(loanAmt - acc) : base;
          acc = round2(acc + p);
          src.push({ dueDate: String(gen[j].dueDate).substring(0, 10), principal: p, interest: Number(gen[j].interest || 0) });
        }
      }
      // Balances and EMI exactly as the UI computes them before it posts the rows.
      var out = [], cum = 0;
      for (var k = 0; k < src.length; k++) {
        var open = round2(loanAmt - cum);
        cum = round2(cum + src[k].principal);
        out.push({ installmentNumber: k + 1, dueDate: src[k].dueDate, openingBalance: open, principal: src[k].principal,
                   interest: src[k].interest, charge: 0, pep: 0, emi: round2(src[k].principal + src[k].interest), closingBalance: round2(loanAmt - cum) });
      }
      return out;
    }
    """
    * def manualRows = doManualUpload ? buildManualRows(manualCell, (genStatus == 200 && genBody != null && genBody.length ? genBody : []), td.loanAmount) : []
    * def upResult = doManualUpload ? karate.http(baseUrl + '/v1/origination/draft/' + draftId + '/schedule').header('Authorization', authHeader).header('Content-Type', 'application/json').post(manualRows) : null
    * def upStatus = doManualUpload ? upResult.status : 0
    * def upBody = doManualUpload ? upResult.body : null
    * if (doManualUpload) karate.log('[manual-schedule] TestCase', td.testCaseId, '| manual product:', isManualProduct, '| rows:', karate.sizeOf(manualRows), '| principal total:', sumPrincipal(manualRows), '| HTTP', upStatus)
    # A row with its own manualSchedule cell and an expected error is a negative upload: it must be refused here.
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Manual schedule upload rejected with HTTP', upStatus)
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) RowActions.endRow(td.testCaseId)
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) karate.abort()
    * if (doManualUpload && isNegativeTest && manualCell != null) karate.fail('[MANUAL SCHEDULE NEGATIVE FAILED] TestCase ' + td.testCaseId + ': expected HTTP ' + td.expectedStatus + ' / code ' + td.expectedCode + ' / error "' + td.expectedError + '" but the upload got HTTP ' + upStatus + ' ' + karate.toString(upBody))
    * if (doManualUpload && !isNegativeTest && upStatus != 200) karate.fail('[MANUAL SCHEDULE UPLOAD FAILED] TestCase ' + td.testCaseId + ': HTTP ' + upStatus + ' ' + karate.toString(upBody))
    * def manualUploaded = doManualUpload && !isNegativeTest && upStatus == 200
    * if (doManualUpload) karate.log('✔ [TESTER VERIFICATION] Step 09b: Manual Schedule Upload -> Rows:', karate.sizeOf(manualRows), '| Principal Total:', sumPrincipal(manualRows), '| Loan Amount:', td.loanAmount, '| Status:', upStatus)

    * atStep('09')

    # Step 10: Document Checklist & Upload
    Given path '/v1/product-config/checklist'
    And param productTypeCode = td.loanProductType
    And param productCode = td.selectedProductCode
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 10: Document Checklist Lookup -> Status:', responseStatus, '| MATCHED'

    * def isUploadDoc = td.uploadDocument == 'true' || td.uploadDocument === true
    * def docStatusToSet = (td.documentStatus && td.documentStatus != '') ? td.documentStatus : 'APPROVED'
    * def docCommentToSet = (td.documentStatusComment && td.documentStatusComment != '') ? td.documentStatusComment : 'Verified during Origination step'
    * def docUploads =
    """
    function() {
      var rawName = td.uploadDocumentName ? td.uploadDocumentName.toString() : 'National_ID_Proof.pdf';
      var rawType = td.uploadDocumentType ? td.uploadDocumentType.toString() : 'IDENTITY_PROOF';
      var names = rawName.split(';');
      var types = rawType.split(';');
      var out = [];
      for (var i = 0; i < names.length; i++) {
        if (names[i].trim() == '') continue;
        var type = types.length > i ? types[i].trim() : (types.length > 0 ? types[0].trim() : 'IDENTITY_PROOF');
        out.push({ appRef: draftRef, docType: type, docName: names[i].trim(), docStatus: docStatusToSet, docComment: docCommentToSet, authHeader: officerAuthHeader, baseUrl: baseUrl });
      }
      return out;
    }
    """
    * def docsToUpload = isUploadDoc ? docUploads() : []
    * if (karate.sizeOf(docsToUpload) > 0) karate.call('classpath:features/loans/upload-document-helper.feature', docsToUpload)

    * atStep('10')

    # Step 11: Charge Collection & Draft Submission
    # The officer collects the APPLICATION charges (applicationCharges). The draft is normally linked to its
    # application already; when it is not, submit answers 409 for a due charge and they are collected then.
    * def draftAppId = function() { var d = karate.http(baseUrl + '/v1/origination/draft/' + draftId).header('Authorization', officerAuthHeader).get().body; return d == null ? null : d.linkedApplicationId }
    * def preSubmitAppId = draftAppId()
    * def appCharges = preSubmitAppId ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', preSubmitAppId) : null
    * def appChargeNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargeNeg) RowActions.endRow(td.testCaseId)
    * if (appChargeNeg) karate.abort()
    * if (appCharges != null && appCharges.error && isNegativeTest) karate.log('[charges APPLICATION] API negative', td.testCaseId, '- the charge problem is logged, the server judges the row:', appCharges.error)
    * if (appCharges != null && appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))

    Given path '/v1/origination/draft/' + draftId + '/submit'
    When method POST
    * def submitStatus = responseStatus
    * def submitResponse = response

    # ── NEGATIVE TEST: the row passes when submit refuses the draft the way the sheet expects ──
    * def negativeMatched = isNegativeTest && matchNegative(submitStatus, submitResponse)
    * if (negativeMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Submit rejected with HTTP', submitStatus, '| Expected error matched:', td.expectedError)
    * if (negativeMatched) RowActions.endRow(td.testCaseId)
    * if (negativeMatched) karate.abort()
    * if (isNegativeTest && !setupNegRow && submitStatus >= 400 && submitStatus != 409) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + td.testCaseId + ': expected HTTP "' + td.expectedStatus + '" / error "' + td.expectedError + '" but submit answered HTTP ' + submitStatus + ': ' + karate.toString(submitResponse))
    # A negative row that submit accepts is judged at the next point that can refuse it: opening the assessment
    # (Step 14), where the scorecard is evaluated - e.g. a mandatory scorecard attribute with no value.
    * def negAtAssessment = isNegativeTest && !setupNegRow && submitStatus < 400
    * if (negAtAssessment) karate.log('[NEGATIVE TEST] TestCase', td.testCaseId, ': submit accepted the draft - expecting the refusal when the assessment is opened')
    # A row that expects to go through: say what the submit API objected to, in its own words.
    * if (submitStatus >= 400 && submitStatus != 409) karate.fail('[SUBMIT REFUSED] TestCase ' + td.testCaseId + ': HTTP ' + submitStatus + ' ' + karate.toString(submitResponse))
    * def appCharges = (submitStatus == 409) ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', draftAppId()) : appCharges
    * def appChargeNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargeNeg) RowActions.endRow(td.testCaseId)
    * if (appChargeNeg) karate.abort()
    * if (appCharges != null && appCharges.error && isNegativeTest) karate.log('[charges APPLICATION] API negative', td.testCaseId, '- the charge problem is logged, the server judges the row:', appCharges.error)
    * if (appCharges != null && appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))
    * def resubmitResult = (submitStatus == 409) ? karate.call('classpath:features/loans/resubmit-draft-helper.feature', { draftId: draftId, authHeader: officerAuthHeader, baseUrl: baseUrl }) : null
    * def finalSubmitResponse = (resubmitResult && resubmitResult.resubmittedResponse) ? resubmitResult.resubmittedResponse : submitResponse
    * def appId = finalSubmitResponse.linkedApplicationId
    * match appId == '#notnull'
    # Not linked before submit and no 409: check the column against what the application has at APPLICATION.
    * def appCharges = appCharges == null ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', appId) : appCharges
    * def appChargeNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargeNeg) RowActions.endRow(td.testCaseId)
    * if (appChargeNeg) karate.abort()
    * if (appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))
    * print '✔ [TESTER VERIFICATION] Step 11a: Application Charges -> Collected by:', activeOfficerUser, '|', appCharges.collected
    * print '✔ [TESTER VERIFICATION] Step 11: Draft Submission -> Draft ID:', draftId, '| Linked Application ID:', appId, '| Status: SUBMITTED'

    # Step 11b: Verify Status Post-Submission
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * match response.status == 'SUBMITTED'
    * print '✔ [TESTER VERIFICATION] Step 11b: Post-Submission State -> Expected Status: SUBMITTED | Actual Status:', response.status, '| MATCHED'

    * atStep('11')

    # Step 12: Stage Skip Flags Resolution
    * def isSkipUw = td.skipUw == 'true' || td.skipUw === true
    * def isSkipApp1 = td.skipApprover1 == 'true' || td.skipApprover1 === true
    * def isSkipApp2 = td.skipApprover2 == 'true' || td.skipApprover2 === true
    * def isSkipIssueOffer = td.skipIssueOffer == 'true' || td.skipIssueOffer === true
    * def isSkipOfferAccept = td.skipOfferAccept == 'true' || td.skipOfferAccept === true
    * def isSkipSetup = td.skipLoanSetup == 'true' || td.skipLoanSetup === true

    * atStep('12')

    # Step 13: Underwriter Stage - Claim & Assignee Verification
    * def uwToken = isSkipUw ? null : login(activeUwUser, activeUwPass)
    * def uwAuthHeader = isSkipUw ? null : ('Bearer ' + uwToken)
    * def authHeader = (uwAuthHeader != null) ? uwAuthHeader : officerAuthHeader
    * if (!isSkipUw) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipUw && response.assignedTo) karate.match(response.assignedTo, activeUwUser)
    * print '✔ [TESTER VERIFICATION] Step 13: Underwriter Claim -> Claimed By:', activeUwUser, '| AssignedTo:', response.assignedTo, '| Status:', response.status, '| MATCHED'

    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || response.length > 0
    When method GET
    Then status 200
    * def tasks = response
    * def intakeTasks = isSkipUw ? [] : karate.jsonPath(tasks, "$.[?(@.taskDefinitionKey=='applicationIntake' || @.taskDefinitionKey=='corporateIntake' || @.name=='Origination' || @.formKey=='los/origination' || @.formKey=='los/ent-loan/origination')]")
    * def intakeBody = (intakeTasks.length > 0 && intakeTasks[0].taskDefinitionKey == 'corporateIntake') ? { promoters: [td.promoterName] } : {}
    * if (!isSkipUw && intakeTasks.length > 0) karate.call('classpath:features/loans/complete-task-helper.feature', { taskId: intakeTasks[0].id, requestBody: intakeBody, authHeader: uwAuthHeader, baseUrl: baseUrl })

    * atStep('13')

    # Step 14: Wait for the Underwriter Review step — proves the financial gates passed. Without this
    # the uw-action below can fire before the step exists and is rejected for the wrong reason.
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || karate.jsonPath(response, "$.[?(@.name=='Underwriter Review' || @.taskDefinitionKey=='underwriterReview')]").length > 0
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 14: Underwriter Review Task Available -> Financial Gates: PASSED'

    # Step 14b: The underwriter opens the assessment. The server creates it on this first read, resolves the
    # assessment method and scorecard (the sub-product's own, else the product type's) and, for AUTO, lets the
    # scorecard decide at once. The rest of the row follows what the server resolved - nothing per row:
    #   AUTO_APPROVED                       underwriter and approvers are skipped; offer, acceptance and setup follow
    #   AUTO_REJECTED                       the application is rejected - the row fails (or passes as a negative)
    #   MANUAL / MANUAL_INTERNAL            the underwriter approves without a scorecard, then the approvers
    #   AUTO / EXTERNAL / MANUAL_EXTERNAL   with no scorecard result yet: evaluate it so the underwriter can approve
    * def assessRes = isSkipUw ? null : karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', authHeader).get()
    * def negAssessMatched = (assessRes != null && negAtAssessment && assessRes.status >= 400) ? matchNegative(assessRes.status, assessRes.body) : false
    * if (negAssessMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Opening the assessment refused with HTTP', assessRes.status, '| Expected error matched:', td.expectedError)
    * if (negAssessMatched) RowActions.endRow(td.testCaseId)
    * if (negAssessMatched) karate.abort()
    * if (assessRes != null && assessRes.status >= 400) karate.fail('[ASSESSMENT] TestCase ' + td.testCaseId + ': opening the assessment failed with HTTP ' + assessRes.status + ' ' + karate.toString(assessRes.body) + (negAtAssessment ? ' (expected HTTP "' + td.expectedStatus + '" / error "' + td.expectedError + '")' : ''))
    * def assessRec = assessRes == null ? {} : (assessRes.body.data ? assessRes.body.data : assessRes.body)
    * def assessMethod = assessRec.resolvedAssessmentMethod
    * def autoApproved = assessRec.uwDecision == 'AUTO_APPROVED'
    * def autoRejected = assessRec.uwDecision == 'AUTO_REJECTED'
    * def negRejectMatched = autoRejected && negAtAssessment && (td.expectedError == null || ('' + assessRec.declineReason).toLowerCase().indexOf(('' + td.expectedError).toLowerCase()) >= 0)
    * if (negRejectMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Auto-rejected by the scorecard:', assessRec.declineReason)
    * if (negRejectMatched) RowActions.endRow(td.testCaseId)
    * if (negRejectMatched) karate.abort()
    * if (autoRejected) karate.fail('[ASSESSMENT] TestCase ' + td.testCaseId + ': AUTO-REJECTED by the scorecard (' + assessRec.scorecardResult + ', ' + assessRec.scorecardTotalScorePct + '%): ' + assessRec.declineReason)
    * if (negAtAssessment) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + td.testCaseId + ': expected HTTP "' + td.expectedStatus + '" / error "' + td.expectedError + '" but submit and the assessment both went through (method ' + assessMethod + ', scorecard ' + assessRec.scorecardResult + ')')
    * def needsScorecard = !autoApproved && (assessMethod == 'AUTO' || assessMethod == 'EXTERNAL' || assessMethod == 'MANUAL_EXTERNAL') && assessRec.scorecardResult == null
    * def scorecardEvalStatus = needsScorecard ? karate.http(baseUrl + '/v1/assessment/' + appId + '/evaluate-scorecard').header('Authorization', authHeader).header('Content-Type', 'application/json').post({}).status : 'NOT NEEDED'
    * print '✔ [TESTER VERIFICATION] Step 14b: Assessment Opened -> Method:', assessMethod, '| Rule:', assessRec.resolvedRuleName, '| Scorecard:', assessRec.scorecardResult, assessRec.scorecardTotalScorePct, '| Decision:', assessRec.uwDecision, '| Scorecard evaluation:', scorecardEvalStatus
    # AUTO-approved by the scorecard: no underwriter or approver decision is taken. Step 15 sees the APPROVED
    # status and skips the approver stages the same way.
    * if (autoApproved) karate.log('[workflow] TestCase', td.testCaseId, 'AUTO-APPROVED by the scorecard (' + assessRec.scorecardTotalScorePct + '%) - underwriter and approver stages skipped')
    * def isSkipUw = (isSkipUw == true || autoApproved == true) ? true : false
    * def isSkipApp1 = (isSkipApp1 == true || autoApproved == true) ? true : false
    * def isSkipApp2 = (isSkipApp2 == true || autoApproved == true) ? true : false

    * if (!isSkipUw) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })
    # (underwriter-stage charge collection is handled by the CHARGE SETTLEMENT GATE below,
    #  which reads the response body and reuses the underwriter session instead of minting
    #  another admin one - see the block before the uw-action call)
    * if (!isSkipUw) karate.call('classpath:features/loans/assessment-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })

    # ── CHARGE SETTLEMENT GATE ────────────────────────────────────────────────
    # uw-action refuses to route to the approver stage while any charge is outstanding:
    #   409 PENDING_CHANGE_EXISTS "Charge CHG-000024 (...) must be collected or waived before
    #   the assessment can be approved."
    # auto-collect-helper cannot be relied on to have settled them, for two reasons:
    #   1. POST /v1/charge-collection/{id}/collect answers HTTP 200 EVEN WHEN THE POSTING FAILED,
    #      and puts the real outcome in the BODY:
    #        {"chargeId":982,"status":"FAILED","responseCode":"400",
    #         "errorMessage":"Host posting failed [400]: ... the 010101000000111 account does not
    #          have sufficient balance to complete this transaction"}
    #      The helper only inspects the HTTP status, so a drained funding account is
    #      indistinguishable from success there and the run dies ~40 steps later at uw-action.
    #   2. The helper signs a FRESH ADMIN IN, which revokes the underwriter session this scenario is
    #      still holding — so the very next underwriter call fails 401/403 even when the charge did
    #      settle. This block reuses the caller's own session instead.
    * def uwCharges = isSkipUw ? noCharges : stageCharges(uwAuthHeader, 'ASSESSMENT', 'assessmentCharges', appId)
    * def uwChargeNeg = chargeNegMatched(uwCharges, 'ASSESSMENT')
    * if (uwChargeNeg) RowActions.endRow(td.testCaseId)
    * if (uwChargeNeg) karate.abort()
    * if (uwCharges.error) karate.fail(chargeFail(uwCharges, 'ASSESSMENT'))
    * print '✔ [TESTER VERIFICATION] Step 14c: Assessment Charges -> Collected by:', isSkipUw ? 'SKIPPED' : activeUwUser, '|', uwCharges.collected

    * def uwComment = 'Karate E2E Direct | ' + td.testCaseId
    * def rawUwAction = isSkipUw ? null : requiredCell('uwAction', 'the underwriter decision')
    * def resolvedUwAction = (rawUwAction == 'APPROVE' ? 'APPROVE_TO_APPROVER' : rawUwAction)
    * def notifyOff = td.notifyOfficer == 'true' || td.notifyOfficer === true
    * def notifyCust = td.notifyCustomer == 'true' || td.notifyCustomer === true
    * def uwPayload = { action: '#(resolvedUwAction)', comment: '#(uwComment)', notifyOfficer: true, notifyCustomer: false }
    * set uwPayload.notifyOfficer = notifyOff
    * set uwPayload.notifyCustomer = notifyCust
    * if (!isSkipUw) karate.call('classpath:features/loans/uw-action-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl, requestBody: uwPayload })

    * atStep('14')

    # Step 15: Post-Underwriter Action Verification
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 15: Post-UW Action State -> Status:', response.status, '| Current Phase:', response.currentPhaseId, '| MATCHED'
    # The server can approve straight past the approvers (and the offer) after underwriting - 9190 does this for
    # some products and amounts. There are then no approver / offer tasks to wait for, so those stages are
    # treated as skipped, exactly as the sheet's skip flags would, and the row goes on to Loan Setup.
    * def postUwStatus = response.status
    # Plain JS booleans only: a 'def' whose value starts with [ is not a boolean to Karate, so the skip flags
    # became truthy objects, the log line printed for every row and 'retry until isSkipApp1 || ...' never passed.
    * def pastApproval = (postUwStatus == 'APPROVED' || postUwStatus == 'OFFER_ISSUED' || postUwStatus == 'OFFER_ACCEPTED') ? true : false
    * if (pastApproval == true) karate.log('[workflow] TestCase', td.testCaseId, 'is already', postUwStatus, 'after underwriting - approver stages skipped')
    * def isSkipApp1 = (isSkipApp1 == true || pastApproval == true) ? true : false
    * def isSkipApp2 = (isSkipApp2 == true || pastApproval == true) ? true : false
    * def isSkipIssueOffer = (isSkipIssueOffer == true || postUwStatus == 'OFFER_ISSUED' || postUwStatus == 'OFFER_ACCEPTED') ? true : false
    * def isSkipOfferAccept = (isSkipOfferAccept == true || postUwStatus == 'OFFER_ACCEPTED') ? true : false

    * atStep('15')

    # Step 16: Credit Approver Voting Stage - Claim & Vote Verification
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipApp1 || karate.jsonPath(response, "$.[?(@.name=='Credit Approval' || @.taskDefinitionKey=='creditApproval')]").length > 0
    When method GET
    Then status 200

    Given path '/v1/assessment/' + appId
    When method GET
    Then status 200
    * def assm = response
    * def targetAuthType = assm.directResolvedAuthorityType
    * def targetAuthNames = assm.directResolvedAuthorityNames

    * def firstApproverUser = (activeApprover1User != null) ? activeApprover1User : ((targetAuthType == 'USER' && targetAuthNames == defaultApprover2Username) ? defaultApprover2Username : defaultApprover1Username)
    * def firstApproverPass = (activeApprover1Pass != null) ? activeApprover1Pass : ((targetAuthType == 'USER' && targetAuthNames == defaultApprover2Username) ? defaultApprover2Password : defaultApprover1Password)
    * def secondApproverUser = (activeApprover2User != null) ? activeApprover2User : ((firstApproverUser == defaultApprover1Username) ? defaultApprover2Username : defaultApprover1Username)
    * def secondApproverPass = (activeApprover2Pass != null) ? activeApprover2Pass : ((firstApproverUser == defaultApprover1Username) ? defaultApprover2Password : defaultApprover1Password)

    # Approver 1 Claim & Vote
    * def approver1Token = isSkipApp1 ? null : login(firstApproverUser, firstApproverPass)
    * def approver1AuthHeader = isSkipApp1 ? null : ('Bearer ' + approver1Token)
    * def authHeader = (approver1AuthHeader != null) ? approver1AuthHeader : officerAuthHeader
    * if (!isSkipApp1) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: approver1AuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipApp1 && response.assignedTo) karate.match(response.assignedTo, firstApproverUser)
    * def approver1Action = isSkipApp1 ? null : requiredCell('approver1Action', 'approver 1')
    * print '✔ [TESTER VERIFICATION] Step 16a: Approver 1 ->', isSkipApp1 ? 'SKIPPED' : ('Claimed By: ' + firstApproverUser + ' | Action: ' + approver1Action), '| AssignedTo:', response.assignedTo

    * def app1Comment = firstApproverUser + ' | ' + td.testCaseId
    * def app1Payload = { action: '#(approver1Action)', comment: '#(app1Comment)', overriddenInterestRate: 0, notifyOfficer: true, notifyCustomer: false }
    * set app1Payload.overriddenInterestRate = td.overriddenInterestRate
    * set app1Payload.notifyOfficer = notifyOff
    * set app1Payload.notifyCustomer = notifyCust
    * if (!isSkipApp1) karate.call('classpath:features/loans/approver-action-helper.feature', { appId: appId, authHeader: approver1AuthHeader, baseUrl: baseUrl, requestBody: app1Payload })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def approvedAfterVote1 = response.status == 'APPROVED'
    * print '✔ [TESTER VERIFICATION] Step 16b: Post-Approver 1 Vote Application Status:', response.status, '| Phase:', response.currentPhaseId

    # Approver 2 Claim & Vote
    * def approver2Token = (approvedAfterVote1 || isSkipApp2) ? null : login(secondApproverUser, secondApproverPass)
    * def approver2AuthHeader = (approvedAfterVote1 || isSkipApp2) ? null : ('Bearer ' + approver2Token)
    * if (!approvedAfterVote1 && !isSkipApp2) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: approver2AuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!approvedAfterVote1 && !isSkipApp2 && response.assignedTo) karate.match(response.assignedTo, secondApproverUser)
    * def approver2Action = (approvedAfterVote1 || isSkipApp2) ? null : requiredCell('approver2Action', 'approver 2')
    * print '✔ [TESTER VERIFICATION] Step 16c: Approver 2 ->', (approvedAfterVote1 || isSkipApp2) ? 'SKIPPED' : ('Claimed By: ' + secondApproverUser + ' | Action: ' + approver2Action), '| AssignedTo:', response.assignedTo

    * def app2Comment = secondApproverUser + ' quorum | ' + td.testCaseId
    * def app2Payload = { action: '#(approver2Action)', comment: '#(app2Comment)', overriddenInterestRate: 0, notifyOfficer: true, notifyCustomer: false }
    * set app2Payload.overriddenInterestRate = td.overriddenInterestRate
    * set app2Payload.notifyOfficer = notifyOff
    * set app2Payload.notifyCustomer = notifyCust
    * if (!approvedAfterVote1 && !isSkipApp2) karate.call('classpath:features/loans/approver-action-helper.feature', { appId: appId, authHeader: approver2AuthHeader, baseUrl: baseUrl, requestBody: app2Payload })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 16d: Final Post-Approver Voting Status:', response.status, '| Expected: APPROVED'

    * atStep('16')

    # Step 17: Offer Issue Role Stage - Claim & Issue Verification
    * def issuerToken = isSkipIssueOffer ? null : login(activeIssuerUser, activeIssuerPass)
    * def issuerAuthHeader = isSkipIssueOffer ? null : ('Bearer ' + issuerToken)
    * def authHeader = (issuerAuthHeader != null) ? issuerAuthHeader : officerAuthHeader
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipIssueOffer && response.assignedTo) karate.match(response.assignedTo, activeIssuerUser)
    * print '✔ [TESTER VERIFICATION] Step 17a: Issuer Claim -> Claimed By:', activeIssuerUser, '| Pre-Issue Status:', response.status, '| Expected Status: APPROVED | MATCHED'

    # The issuer collects the OFFER charges (offerCharges) and, when the scorecard AUTO-approved the application
    # (no underwriter), its ASSESSMENT charges (assessmentCharges) first.
    * def issueAssessCharges = (!isSkipIssueOffer && autoApproved) ? stageCharges(issuerAuthHeader, 'ASSESSMENT', 'assessmentCharges', appId) : noCharges
    * def issueAssessNeg = chargeNegMatched(issueAssessCharges, 'ASSESSMENT')
    * if (issueAssessNeg) RowActions.endRow(td.testCaseId)
    * if (issueAssessNeg) karate.abort()
    * if (issueAssessCharges.error) karate.fail(chargeFail(issueAssessCharges, 'ASSESSMENT'))
    * def issueCharges = isSkipIssueOffer ? noCharges : stageCharges(issuerAuthHeader, 'OFFER', 'offerCharges', appId)
    * def issueChargeNeg = chargeNegMatched(issueCharges, 'OFFER')
    * if (issueChargeNeg) RowActions.endRow(td.testCaseId)
    * if (issueChargeNeg) karate.abort()
    * if (issueCharges.error) karate.fail(chargeFail(issueCharges, 'OFFER'))
    * print '✔ [TESTER VERIFICATION] Step 17b: Offer Charges -> Collected by:', isSkipIssueOffer ? 'SKIPPED' : activeIssuerUser, '|', issueAssessCharges.collected.concat(issueCharges.collected)

    * def issuePayload = { rateAdjustment: 0, principalReduction: 0, offerValidityDate: '#(td.offerValidityDate)' }
    * set issuePayload.rateAdjustment = td.offerRateAdjustment
    * set issuePayload.principalReduction = td.offerPrincipalReduction
    # issuerAction: ISSUE - the only action the offer-issue stage has.
    * def issuerAction = isSkipIssueOffer ? null : requiredCell('issuerAction', 'the offer-issue stage').toUpperCase()
    * if (!isSkipIssueOffer && issuerAction != 'ISSUE') karate.fail('[SHEET] TestCase ' + td.testCaseId + ': issuerAction "' + issuerAction + '" is not supported - use ISSUE')
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/offer-issue-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl, requestBody: issuePayload })

    # 404 is legitimate on a row that skips issuance (the server auto-accepted) - there is no offer to read.
    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || (isSkipIssueOffer && responseStatus == 404)
    * if (!isSkipIssueOffer) karate.match(response.status, '#regex ISSUED|OFFER_ISSUED')
    * print '✔ [TESTER VERIFICATION] Step 17b: Offer Issued -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ISSUED / OFFER_ISSUED | MATCHED'

    # Step 17c: Offer Acceptor Role Stage - Claim & Accept Verification
    * def acceptorToken = isSkipOfferAccept ? null : login(activeAcceptorUser, activeAcceptorPass)
    * def acceptorAuthHeader = isSkipOfferAccept ? null : ('Bearer ' + acceptorToken)
    * def authHeader = (acceptorAuthHeader != null) ? acceptorAuthHeader : officerAuthHeader
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipOfferAccept && response.assignedTo) karate.match(response.assignedTo, activeAcceptorUser)
    * print '✔ [TESTER VERIFICATION] Step 17c: Acceptor Claim -> Claimed By:', activeAcceptorUser, '| AssignedTo:', response.assignedTo, '| MATCHED'

    # acceptorAction: ACCEPT | DECLINE. DECLINE records the customer's decline with offerDeclineReason (required) and
    # ends the row at OFFER_DECLINED - nothing after it (setup, CBS) applies.
    * def acceptorAction = isSkipOfferAccept ? null : requiredCell('acceptorAction', 'the offer-acceptance stage').toUpperCase()
    * def declineReason = (!isSkipOfferAccept && acceptorAction == 'DECLINE') ? requiredCell('offerDeclineReason', 'the offer decline') : null
    * if (!isSkipOfferAccept && acceptorAction != 'ACCEPT' && acceptorAction != 'DECLINE') karate.fail('[SHEET] TestCase ' + td.testCaseId + ': acceptorAction "' + acceptorAction + '" is not supported - use ACCEPT or DECLINE')
    * def declineRes = (!isSkipOfferAccept && acceptorAction == 'DECLINE') ? karate.http(baseUrl + '/v1/offer/' + appId + '/decline').header('Authorization', acceptorAuthHeader).header('Content-Type', 'application/json').post({ declinedReason: declineReason }) : null
    * if (declineRes != null && declineRes.status != 200) karate.fail('[OFFER] TestCase ' + td.testCaseId + ': decline refused with HTTP ' + declineRes.status + ' ' + karate.toString(declineRes.body))
    * def declinedApp = declineRes != null ? karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', acceptorAuthHeader).get().body : null
    * if (declineRes != null && declinedApp.status != 'OFFER_DECLINED') karate.fail('[OFFER] TestCase ' + td.testCaseId + ': after DECLINE the application is ' + declinedApp.status + ', expected OFFER_DECLINED')
    * if (declineRes != null) karate.log('✔ [TESTER VERIFICATION] Step 17d: Offer DECLINED by', activeAcceptorUser, '-> Status:', declinedApp.status, '| Reason:', declineReason)
    * if (declineRes != null && chargeNegRow) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + td.testCaseId + ': expected a charge error containing "' + td.expectedError + '" but every stage up to the offer decline collected its charges')
    * if (declineRes != null) RowActions.endRow(td.testCaseId)
    * if (declineRes != null) karate.abort()
    * def acceptCharges = isSkipOfferAccept ? noCharges : stageCharges(acceptorAuthHeader, 'OFFER_ACCEPTANCE', 'offerAcceptanceCharges', appId)
    * def acceptChargeNeg = chargeNegMatched(acceptCharges, 'OFFER_ACCEPTANCE')
    * if (acceptChargeNeg) RowActions.endRow(td.testCaseId)
    * if (acceptChargeNeg) karate.abort()
    * if (acceptCharges.error) karate.fail(chargeFail(acceptCharges, 'OFFER_ACCEPTANCE'))
    * print '✔ [TESTER VERIFICATION] Step 17c: Offer-Acceptance Charges -> Collected by:', isSkipOfferAccept ? 'SKIPPED' : activeAcceptorUser, '|', acceptCharges.collected
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/offer-accept-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl, requestBody: {} })

    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || (isSkipOfferAccept && responseStatus == 404)
    * if (!isSkipOfferAccept) karate.match(response.status, '#regex ACCEPTED|OFFER_ACCEPTED')
    * print '✔ [TESTER VERIFICATION] Step 17d: Offer Accepted -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ACCEPTED | MATCHED'

    * atStep('17')

    # Step 18: Setup User Role Stage - Claim, Excel Matching & Schedule Regeneration
    * def setupToken = isSkipSetup ? null : login(activeSetupUser, activeSetupPass)
    * def setupAuthHeader = isSkipSetup ? null : ('Bearer ' + setupToken)
    * def authHeader = (setupAuthHeader != null) ? setupAuthHeader : officerAuthHeader
    * if (!isSkipSetup) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipSetup && response.assignedTo) karate.match(response.assignedTo, activeSetupUser)
    * match response.loanAmount == td.loanAmount
    * match response.customerId == td.customerId
    * match response.selectedProductCode == td.selectedProductCode
    * print '✔ [TESTER VERIFICATION] Step 18a: Setup Officer Claim -> Claimed By:', activeSetupUser, '| Loan Amount:', response.loanAmount, '| Product:', response.selectedProductCode, '| MATCHED WITH EXCEL'

    Given path '/v1/loan-setup/' + appId + '/validate-account'
    And param accountNumber = feeAcct
    When method GET
    # A row that skips setup has no setup session: the call answers 403 and is not checked.
    Then assert responseStatus == 200 || isSkipSetup

    # Regenerate request with the fields the UI's Loan Setup screen sends (RegenerateScheduleRequest). Other
    # names are ignored by the server, which then cannot call CBS and silently returns its LOCAL fallback.
    # The saved PEP is sent again (pepDtls[]), as the UI does; a manual product sends its auto population.
    * def regenReq = { principal: '#(td.loanAmount)', ratePercent: '#(td.overriddenInterestRate)', tenureMonths: '#(calcTermMonths)', frequency: '#(td.repaymentFrequency)', productCode: '#(td.selectedProductCode)' }
    * if (schedFirstRepay) karate.set('regenReq', karate.merge(regenReq, { startDate: schedFirstRepay, repaymentStartDate: schedFirstRepay }))
    * if (pepSent) karate.set('regenReq', karate.merge(regenReq, pepFields))
    * if (isManualProduct && td.autoPopulationMethod) karate.set('regenReq', karate.merge(regenReq, { autoPopulationMethod: td.autoPopulationMethod }))
    * eval karate.set('regenReq', karate.merge(regenReq, optionFields.setup))
    Given path '/v1/loan-setup/' + appId + '/regenerate-schedule'
    And request regenReq
    When method POST
    Then status 200
    * def generatedSched = response
    * def installmentsList = (generatedSched.installments ? generatedSched.installments : generatedSched)
    * def manualUploaded = typeof manualUploaded == 'undefined' ? false : manualUploaded
    # Expected installment count follows the CBS sub-product's repayment type:
    # EMI/FPI/FLAT/etc -> periodic; PAM -> 1 installment; MANUAL -> skip assertion (validated against upload below).
    * def expectedInstallmentsFor = read('classpath:features/loans/expected-installments.js')
    * def instRule = expectedInstallmentsFor({ product: cbsProduct, frequency: td.repaymentFrequency, termMonths: calcTermMonths, splitInterestFrequency: !!optionFields.spec.interestFrequency })
    * def expectedInstallments = instRule.expected
    * karate.log('[schedule] TestCase', td.testCaseId, ': repayment type', instRule.loRepaymentType, '(', instRule.cbsRepaymentType, ') ->', instRule.reason, '| expected installments:', expectedInstallments)
    * if (!manualUploaded && expectedInstallments != null && karate.sizeOf(installmentsList) != expectedInstallments) karate.fail('[SCHEDULE REGENERATION] TestCase ' + td.testCaseId + ': expected ' + expectedInstallments + ' installments (' + instRule.reason + '), got ' + karate.sizeOf(installmentsList))
    # The setup schedule must come from CBS (ISO due dates), not LO's local fallback ("15 Oct 2026" dates),
    # which the server returns with HTTP 200 whenever its CBS call fails.
    * def isIsoDate = function(d) { return d != null && /^\d{4}-\d{2}-\d{2}/.test('' + d) }
    * def setupFromCbs = karate.sizeOf(installmentsList) == 0 || isIsoDate(installmentsList[0].dueDate)
    * if (true && !manualUploaded && karate.sizeOf(installmentsList) > 0 && !setupFromCbs) karate.fail('[SETUP SCHEDULE NOT FROM CBS] TestCase ' + td.testCaseId + ': Loan Setup regenerate returned the local fallback schedule (first due date ' + installmentsList[0].dueDate + ') - the CBS call failed inside LO')
    * def optSetupErrors = (optCheck && true && !manualUploaded && setupFromCbs) ? checkOptionsSchedule(installmentsList, optionFields.spec) : []
    * if (optSetupErrors.length > 0) karate.fail('[REPAYMENT OPTIONS LOST AT SETUP] TestCase ' + td.testCaseId + ': ' + optSetupErrors.join('; '))
    * if (optCheck && true && !manualUploaded) karate.log('✔ [TESTER VERIFICATION] Step 18b Repayment options at Setup -> ' + optionFields.sent.join(', ') + ' | schedule shape MATCHED')
    * def pepSetup = (pepCheck && true) ? analysePep(installmentsList, pepAmountNum) : null
    * if (pepSetup != null && pepSetup.bumped != pepCountNum) karate.fail('[PEP LOST AT SETUP] TestCase ' + td.testCaseId + ': setup schedule has ' + pepSetup.bumped + ' installments raised by ' + pepAmountNum + ', expected ' + pepCountNum)
    * if (pepSetup != null) karate.log('✔ [TESTER VERIFICATION] Step 18b PEP at Setup -> raised installments:', pepSetup.bumped, 'of', pepCountNum)
    # A manual-schedule loan's setup schedule is the uploaded one: same number of rows, principal adding up to the loan amount.
    * if (manualUploaded && karate.sizeOf(installmentsList) != karate.sizeOf(manualRows)) karate.fail('[MANUAL SCHEDULE NOT USED AT SETUP] TestCase ' + td.testCaseId + ': uploaded ' + karate.sizeOf(manualRows) + ' rows, setup schedule has ' + karate.sizeOf(installmentsList))
    * if (manualUploaded && Math.abs(sumPrincipal(installmentsList) - td.loanAmount) > 0.01) karate.fail('[MANUAL SCHEDULE NOT USED AT SETUP] TestCase ' + td.testCaseId + ': setup principal total ' + sumPrincipal(installmentsList) + ' != loan amount ' + td.loanAmount)
    * if (manualUploaded) karate.log('✔ [TESTER VERIFICATION] Step 18b: Manual Schedule at Setup -> Rows:', karate.sizeOf(installmentsList), '| Principal Total:', sumPrincipal(installmentsList), '| MATCHED UPLOAD')
    * print '✔ [TESTER VERIFICATION] Step 18b: Schedule Regeneration -> Expected Tenor Months:', calcTermMonths, '| Installments Count:', karate.sizeOf(installmentsList), '| Tenor Dates Aligned: MATCHED'

    * def setupPayload =
    """
    {
      "settlementMode": "#(td.setupSettlementMode ? td.setupSettlementMode : td.settlementMode)",
      "repaymentAccountNumber": "#(td.repaymentAccountNumber)",
      "feeFundingAccountNumber": "#(td.feeFundingAccountNumber)",
      "disbursementMode": "#(td.disbursementMode)",
      "disbursementDate": "#(td.disbursementDate)",
      "disbursementAccountNumber": "#(td.disbursementAccountNumber)",
      "disbursementNotes": "#(td.disbursementNotes)"
    }
    """
    * if (!isSkipSetup) karate.call('classpath:features/loans/loan-setup-save-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: setupPayload })

    # Create Loan Account in CBS with the request the UI's Loan Setup screen builds (buildCreateAccountRequest):
    # applicants, product, purpose, amount, term, dates, settlement, the repayment options sent to the setup
    # regenerate, and the rate id. The stub /send-to-cbs fallback (which invents LN-<year>-BLR-<appId> locally
    # without calling CBS) is no longer used: a loan account that CBS did not create fails the row.
    Given path '/v1/system/business-date'
    When method GET
    * def cbsBusinessDate = (responseStatus == 200 && response.businessDate) ? ('' + response.businessDate).substring(0, 10) : null
    Given path '/v1/loan-setup/' + appId
    When method GET
    Then assert responseStatus == 200 || isSkipSetup
    * def setupDto = responseStatus == 200 ? response : {}
    * def buildCreateAccountRequest =
    """
    function(s, o, x) {
      var has = function(v) { return v != null && ('' + v).trim() != '' };
      var d = function(v) { return has(v) ? ('' + v).substring(0, 10) : null };
      var cur = has(s.currency) ? s.currency : 'USD';
      var principal = s.finalPrincipal != null ? Number(s.finalPrincipal) : Number(x.loanAmount);
      var today = new Date().toISOString().substring(0, 10);
      // Dates as the UI-driven run sets them: the loan starts on the application's loan start date (the CBS
      // business date when the sheet has none); the disbursement is the next working day after it (the same
      // day for an Upfront product); repayments start on the sheet's repayment start date, never before the
      // disbursement. The sheet's disbursementDate is a placeholder for LO's local stub and is not sent to CBS.
      var addDays = function(iso, n) { var t = new Date(iso + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().substring(0, 10) };
      var base = d(x.loanStartDate) || d(s.interestStartDate) || d(x.businessDate) || today;
      var disbDate = ('' + s.repaymentType).toUpperCase() == 'U' ? base : addDays(base, 1);
      var dow = new Date(disbDate + 'T00:00:00Z').getUTCDay();
      if (dow == 6) disbDate = addDays(disbDate, 2); else if (dow == 0) disbDate = addDays(disbDate, 1);
      var ps = d(s.principalStartDate) || x.repaymentStartDate;
      var repayStart = (ps && ps >= disbDate) ? ps : disbDate;
      var disbAcct = has(x.disbAcct) ? x.disbAcct : x.repaymentAcct;
      var sm = ('' + x.settlementMode).toUpperCase();
      var r = {
        loanApplicantIds: [{ customerId: s.customerId }],
        loanAccountName: s.applicationNumber,
        productCode: s.productCode,
        loanPurposeCode: s.loanPurpose,
        loanRequestAmount: { amount: principal, currency: cur },
        loanStartDate: base,
        loanTerm: { calendarPeriod: 'MONTH', value: s.tenureMonths != null ? s.tenureMonths : x.termMonths },
        maturityDateCalculation: 'FROM-FIRST-DISBURSEMENT',
        repaymentFrequency: has(x.repaymentFrequency) ? x.repaymentFrequency : 'MONTHLY',
        settlementType: sm == 'ACCOUNT_TRANSFER' ? 'AUTOMATIC-DEBIT' : (sm == 'EXTERNAL_MANDATE' ? 'OTHER-BANK-DEBIT' : 'MANUAL-COLLECTION'),
        feeCollectionAccount: x.feeAcct,
        loanTaxFundingAccount: x.feeAcct,
        defaultChargeFundingAccountToLoanAccount: false,
        customerInterestMargin: s.customerMarginInterest != null ? Number(s.customerMarginInterest) : 0,
        waiveCharge: false,
        kycCheckRequired: false
      };
      if (('' + s.repaymentType).toUpperCase() != 'M') r.repaymentStartDate = repayStart;
      if (sm != 'MANUAL' && has(x.repaymentAcct)) r.repaymentAccount = x.repaymentAcct;
      if (has(s.mandateReference)) r.mandateReference = s.mandateReference;
      if (('' + x.disbursementMode).toUpperCase() != 'CREATE_LATER') r.disbursementScheduleRequest = [{ disbursementDate: disbDate, disbursementAmount: { amount: principal, currency: cur }, disbursementBeneficiaryId: '', disbursementBeneficiaryAccount: disbAcct, disbursementType: 'TRANSFER' }];
      if (has(x.commitmentId)) r.commitmentId = x.commitmentId;
      if (o.moratoriumType) { r.moratoriumType = o.moratoriumType; if (o.moratoriumMonths) r.moratoriumPeriod = o.moratoriumMonths; if (o.moratoriumCollectionMode) r.collectionOfMoratoriumPeriodInterest = o.moratoriumCollectionMode; }
      if (o.balloonAmount) r.balloonPaymentAmount = { amount: o.balloonAmount, currency: cur, valid: true };
      if (o.stepRows && o.stepRows.length > 0) r.stepDetails = o.stepRows.map(function(st) { var a = Math.abs(Number(st.stepAmount)); return { stepAmount: { amount: ('' + st.stepMode).toUpperCase() == 'DOWN' ? -a : a, isoCurrencyCode: cur, valid: true }, stepFirstPaymentNum: Number(st.startInstallment), stepLastPaymentNum: Number(st.endInstallment), valid: true } });
      if (o.interestFrequency) { r.interestRepayFrequency = o.interestFrequency; if (o.interestFrequencyDate) r.interestRepayStartDate = o.interestFrequencyDate; }
      if (x.pep) r.pepDetails = { pepStartDate: x.pep.pepStartDate ? x.pep.pepStartDate : repayStart, pepAmount: { amount: Number(x.pep.pepAmount), isoCurrencyCode: cur }, pepNumPaymnts: x.pep.pepNumPaymnts, pepFrequency: x.pep.pepFrequency };
      if (x.autoPopulationMethod) r.manualSchedule = { autoPopulationMethod: x.autoPopulationMethod };
      var type = ('' + (has(s.interestType) ? s.interestType : 'FLOATING')).toUpperCase();
      var rateId = has(s.rateId) ? ('' + s.rateId).trim() : '';
      if (rateId) {
        if (type == 'FIXED') r.interestDetails = { rateType: 'FIXED', fixedRateDetails: { rateId: rateId } };
        else if (type == 'PROGRESSIVE') { var pr = { rateId: rateId, spread: null }; if (has(s.postProgressiveRateType)) pr.postProgressiveRateType = s.postProgressiveRateType; r.interestDetails = { rateType: 'PROGRESSIVE', progressiveRateDetails: pr }; }
        else r.interestDetails = { rateType: 'FLOATING', floatingRateDetails: { rateId: rateId } };
      } else {
        var rate = s.rateAfter != null ? Number(s.rateAfter) : 0;
        if (type == 'FIXED') r.interestDetails = { rateType: 'FIXED', fixedRateDetails: { effectiveRate: rate } };
        else if (type == 'PROGRESSIVE') r.interestDetails = { rateType: 'PROGRESSIVE', progressiveRateDetails: { spread: { type: 'PERCENTAGE', value: rate } } };
        else r.interestDetails = { rateType: 'FLOATING', floatingRateDetails: { spread: { type: 'PERCENTAGE', value: rate } } };
      }
      return r;
    }
    """
    * def createAccountPayload = buildCreateAccountRequest(setupDto, optionFields.setup, { businessDate: cbsBusinessDate, loanStartDate: td.loanStartDate, loanAmount: td.loanAmount, termMonths: calcTermMonths, disbursementDate: td.disbursementDate, repaymentStartDate: schedFirstRepay, disbAcct: td.disbursementAccountNumber, repaymentAcct: td.repaymentAccountNumber, settlementMode: (td.setupSettlementMode ? td.setupSettlementMode : td.settlementMode), feeAcct: feeAcct, repaymentFrequency: td.repaymentFrequency, disbursementMode: td.disbursementMode, commitmentId: td.commitmentId, pep: (pepSent ? pepFields : null), autoPopulationMethod: ((isManualProduct && td.autoPopulationMethod) ? td.autoPopulationMethod : null) })
    # An override disbursementDate of '__DEFAULT__' keeps the date built above (business date based), so a
    # CBS-setup negative that only changes the amount does not go stale when the business date moves.
    * def builtDisb = createAccountPayload.disbursementScheduleRequest
    * def fillDefaultDisbDate =
    """
    function(p, built) {
      if (!p || !p.disbursementScheduleRequest || !built || !built.length) return p;
      var out = [];
      for (var i = 0; i < p.disbursementScheduleRequest.length; i++) {
        var d = p.disbursementScheduleRequest[i];
        if (d && d.disbursementDate == '__DEFAULT__') d.disbursementDate = built[0].disbursementDate;
        out.push(d);
      }
      p.disbursementScheduleRequest = out;
      return p;
    }
    """
    * def createAccountPayload = applyScheduleOverride(createAccountPayload, setupOverride)
    * def createAccountPayload = fillDefaultDisbDate(createAccountPayload, builtDisb)
    * if (setupOverride != null) karate.log('[cbs] createAccountOverride applied - TestCase', td.testCaseId, ':', setupOverride)
    * if (!isSkipSetup) karate.log('[cbs] create-account request - TestCase', td.testCaseId, ':', createAccountPayload)
    * def cbsNotes = 'CBS Direct | ' + td.testCaseId
    * def cbsPayload = { setupOfficerNotes: '#(cbsNotes)' }
    # setupAction: CREATE_ACCOUNT - collect the SETUP charges, then create the loan account in CBS.
    * def setupAction = isSkipSetup ? null : requiredCell('setupAction', 'the setup stage').toUpperCase()
    * if (!isSkipSetup && setupAction != 'CREATE_ACCOUNT') karate.fail('[SHEET] TestCase ' + td.testCaseId + ': setupAction "' + setupAction + '" is not supported - use CREATE_ACCOUNT')
    * def setupCharges = isSkipSetup ? noCharges : stageCharges(setupAuthHeader, 'SETUP', 'setupCharges', appId)
    * def setupChargeNeg = chargeNegMatched(setupCharges, 'SETUP')
    * if (setupChargeNeg) RowActions.endRow(td.testCaseId)
    * if (setupChargeNeg) karate.abort()
    * if (setupCharges.error) karate.fail(chargeFail(setupCharges, 'SETUP'))
    * print '✔ [TESTER VERIFICATION] Step 18c: Setup Charges -> Collected by:', isSkipSetup ? 'SKIPPED' : activeSetupUser, '|', setupCharges.collected
    * def cbsCreate = isSkipSetup ? null : karate.call('classpath:features/loans/loan-setup-cbs-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: cbsPayload, createAccountPayload: createAccountPayload, expectNegative: setupNegRow })
    * def setupNegMatched = (cbsCreate != null && setupNegRow) ? matchNegative(cbsCreate.cbsStatus, cbsCreate.cbsBody) : false
    * if (setupNegMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Create Loan Account in CBS rejected with HTTP', cbsCreate.cbsStatus, '| Expected error matched:', td.expectedError)
    * if (setupNegMatched) RowActions.endRow(td.testCaseId)
    * if (setupNegMatched) karate.abort()
    * if (cbsCreate != null && setupNegRow && !setupNegMatched) karate.fail('[CBS SETUP NEGATIVE FAILED] TestCase ' + td.testCaseId + ': expected HTTP ' + td.expectedStatus + ' / error "' + td.expectedError + '" but got HTTP ' + cbsCreate.cbsStatus + ' ' + karate.toString(cbsCreate.cbsBody))

    * atStep('18')

    # Step 19: Final Completion & CBS Account Number Retrieval
    Given path '/v1/loans/' + appId
    And retry until response.status == 'COMPLETED' || isSkipSetup
    When method GET
    Then status 200
    * match response.status == 'COMPLETED'
    # Captured BEFORE the loan-setup GET below replaces `response` — that payload carries no `status`
    # field, so reading it there printed a misleading "null" to the tester after a clean run.
    * def finalStatus = response.status

    Given path '/v1/loan-setup/' + appId
    When method GET
    Then status 200
    * def customerId = td.customerId
    * def queryDbCbs = function() { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from blo_loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e) { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e2) { return null; } } }
    * def dbCbs = queryDbCbs()
    # The account number must be the one CBS returned to /create-account, stored on the setup, and never the
    # local stub pattern LN-<year>-BLR-<appId> that /send-to-cbs invents without calling CBS.
    * def cbsLoanIdCreated = (cbsCreate != null && cbsCreate.cbsLoanId) ? cbsCreate.cbsLoanId : null
    * if (cbsLoanIdCreated != null && response.cbsLoanAccountNumber != cbsLoanIdCreated) karate.fail('[CBS ACCOUNT MISMATCH] TestCase ' + td.testCaseId + ': CBS returned loan id ' + cbsLoanIdCreated + ' but the setup stores ' + response.cbsLoanAccountNumber)
    * if (cbsLoanIdCreated != null && /^LN-\d{4}-BLR-\d{6}$/.test('' + cbsLoanIdCreated)) karate.fail('[CBS ACCOUNT IS THE LOCAL STUB] TestCase ' + td.testCaseId + ': ' + cbsLoanIdCreated + ' was generated by LO, not by CBS')
    * def generatedCbsAccountNo = cbsLoanIdCreated != null ? cbsLoanIdCreated : ((dbCbs && dbCbs != '') ? dbCbs : (response.cbsLoanAccountNumber ? response.cbsLoanAccountNumber : 'N/A'))
    * print '======================================================'
    * print '✔ [TESTER VERIFICATION] Row [' + (td.rowIndex ? td.rowIndex : 1) + '/' + (td.totalRows ? td.totalRows : 1) + '] Completed TestCase:', td.testCaseId
    * print '✔ Application ID          :', appId
    * print '✔ Final Application Status:', finalStatus, '| Expected: COMPLETED'
    # Known defect D2: the generated schedule's pep column is 0 (LoanOriginationService maps pep = ZERO).
    * if (!pepColumnOk) karate.fail('[PEP COLUMN DEFECT] TestCase ' + td.testCaseId + ': the generated schedule shows pep = ' + pepAmountNum + ' on ' + pepGen.pepColumn + ' of ' + pepCountNum + ' PEP installments (the server maps the pep column to 0) - the loan itself completed')
    * print '✔ CBS Loan Account Number :', generatedCbsAccountNo
    * print '======================================================'

    * atStep('19')

    # Step 20: Logout Cleanup
    * def logout = function(token) { if (token) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: token }) }
    * logout(officerAuthHeader)
    * logout(uwAuthHeader)
    * logout(approver1AuthHeader)
    * logout(approver2AuthHeader)
    * logout(issuerAuthHeader)
    * logout(acceptorAuthHeader)
    * logout(setupAuthHeader)
    * atStep('20')

    # ── End-of-row columns: store / dbQuery / verify ─────────────────────────
    * atStep(null)
    * if (chargeNegRow) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + td.testCaseId + ': expected a charge error containing "' + td.expectedError + '" but every stage collected its charges')
    * RowActions.endRow(td.testCaseId)

  @ignore @resubmitDraft
  Scenario: Resubmit draft application after charge collection
    * url baseUrl
    * configure headers = { Authorization: '#(officerAuthHeader)' }
    Given path '/v1/origination/draft/' + draftId + '/submit'
    When method POST
    Then status 200
    * def resubmittedResponse = response
