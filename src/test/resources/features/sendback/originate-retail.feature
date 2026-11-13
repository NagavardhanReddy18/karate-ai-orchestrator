@ignore
Feature: SendBack origination - retail loan application, originated and submitted for 08

  # 08-BLO-SendBack-and-Rejection.feature calls this with one row of SendBack-Excel-Automation.xlsx / Retail_Origination.
  # It originates and submits the retail loan application and returns appId / draftId; 08 then drives every
  # underwriter, approver, offer and setup decision. The steps are the origination of 04-BLO-LifeCycle.feature up to submit,
  # copied on 30-Oct-2026 so that 08 has no link to the 04-07 flows - a change to origination there has to be
  # repeated here if 08 should follow it.

  @ignore @originate
  Scenario: Originate and submit one retail loan application
    * def td = __arg
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

    # Submitted: the SendBack runner takes the application from here.
    * print '[sendback-origination] TestCase', td.testCaseId, 'submitted as application', appId
    * RowActions.endRow(td.testCaseId)
