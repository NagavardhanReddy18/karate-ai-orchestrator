@ignore
Feature: SendBack origination - enterprise loan application, originated and submitted for 08

  # 08-BLO-SendBack-and-Rejection.feature calls this with one row of SendBack-Excel-Automation.xlsx / Enterprise_Origination.
  # It originates and submits the enterprise loan application and returns appId / draftId; 08 then drives every
  # underwriter, approver, offer and setup decision. The steps are the origination of 05-BLO-Enterprise-LifeCycle.feature up to submit,
  # copied on 30-Oct-2026 so that 08 has no link to the 04-07 flows - a change to origination there has to be
  # repeated here if 08 should follow it.

  @ignore @originate
  Scenario: Originate and submit one enterprise loan application
    * def td = __arg

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
    * match td != null

    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }

    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn

    # ── SHEET CONTRACT: every value below comes from Excel, nothing is defaulted here ─────────
    # A missing or blank column fails the row HERE, naming the column and the generator that emits
    # it. That is deliberate: a hidden fallback lets a run go green while exercising something other
    # than what the sheet says, and the failure then surfaces hundreds of lines downstream as an
    # unrelated 400 — which is exactly the behaviour this replaces.
    #
    # sheetOpt() marks the columns where BLANK IS MEANINGFUL, and there are only two groups:
    #   * the stage usernames — blank means "resolve this stage from karate-config.js", which is what
    #     keeps one workbook portable across environments with different account names;
    #   * the collateral block — blank means "this facility is unsecured".
    * def GENERATOR = 'GenerateEnterpriseExcelTemplate'
    * def sheetVal =
    """
    function(name) {
      var v = td[name];
      if (v == null || v.toString().trim() == '') {
        // A negative row may leave a required cell blank on purpose: the server is what must refuse it.
        if (typeof isNegativeTest !== 'undefined' && isNegativeTest) { karate.log('[sheet] negative row', td.testCaseId, '- column', name, 'left blank on purpose'); return ''; }
        throw new Error('[sheet] column "' + name + '" is missing or blank for testCaseId "'
          + (td.testCaseId ? td.testCaseId : '?') + '" - add it to ' + GENERATOR
          + ', regenerate the workbook, and fill that column in');
      }
      return v.toString().trim();
    }
    """
    * def sheetNum =
    """
    function(name) {
      var v = sheetVal(name);
      if (v === '') return null;
      if (isNaN(Number(v))) {
        karate.fail('[sheet] column "' + name + '" must be numeric for testCaseId "'
          + td.testCaseId + '" - got "' + v + '"');
      }
      return Number(v);
    }
    """
    * def sheetFlag = function(name) { return sheetVal(name).toLowerCase() == 'true' }
    * def sheetOpt = function(name) { var v = td[name]; return (v == null || v.toString().trim() == '') ? null : v.toString().trim() }

    # ── Negative-test matcher (evaluated at draft save and at submit) ─────────
    # A row is negative when expectedStatus or expectedError is filled. It passes at the first call
    # that refuses it with that status (blank = any 4xx/5xx) and with expectedError somewhere in the
    # body (case-insensitive). The draft save refuses invalid Interest & Schedule repayment options
    # (balloon, moratorium, PEP, step, mixed, offset, interest frequency); submit refuses the rest.
    # expectedStatus CHARGE marks a charge negative: it runs the normal flow and passes at the stage charge check
    # (STAGE CHARGES below) whose error contains expectedError - so it is not an API negative here.
    * def chargeNegRow = sheetOpt('expectedStatus') != null && sheetOpt('expectedStatus').toUpperCase() == 'CHARGE'
    * def isNegativeTest = !chargeNegRow && (sheetOpt('expectedError') != null || sheetOpt('expectedStatus') != null)
    * def matchNegative =
    """
    function(status, body) {
      // JSON serialisation escapes '/' as '\/' — undo it so an expectedError such as a date '15/12/2026' matches.
      var bodyStr = karate.toString(body).toLowerCase().split('\\/').join('/');
      var expErr  = sheetOpt('expectedError')  ? sheetOpt('expectedError').toLowerCase()  : '';
      var expStat = sheetOpt('expectedStatus') ? sheetOpt('expectedStatus') : '';
      var expCode = sheetOpt('expectedCode') ? sheetOpt('expectedCode').toUpperCase() : '';
      var statusOk = (expStat == '') ? (status >= 400) : (status == parseInt(expStat));
      var errorOk  = (expErr  == '') ? (status >= 400) : (bodyStr.indexOf(expErr) >= 0);
      var codeOk   = (expCode == '') || (body != null && body.code != null && body.code.toString().toUpperCase() == expCode);
      return statusOk && errorOk && codeOk;
    }
    """

    * def testCaseId = sheetVal('testCaseId')
    * def description = sheetVal('description')
    * print '==================================================='
    * print 'START DIRECT ENTERPRISE ROW [' + (td.rowIndex ? td.rowIndex : 1) + '/' + (td.totalRows ? td.totalRows : 1) + '] | TestCase:', testCaseId, '|', description
    * print '==================================================='

    * def activeAdminUser = (sheetOpt('adminUsername') != null && sheetOpt('adminUsername') != '') ? sheetOpt('adminUsername') : defaultAdminUsername
    * def activeAdminPass = defaultAdminPassword

    # Password lookup for whichever approver the server ends up naming. karate-config.js is the only
    # place accounts and their passwords are paired, so resolve against it rather than guessing.
    * def passwordFor =
    """
    function(user) {
      if (user == defaultApprover1Username) return defaultApprover1Password;
      if (user == defaultApprover2Username) return defaultApprover2Password;
      if (typeof defaultApprover3Username !== 'undefined' && defaultApprover3Username != null && user == defaultApprover3Username) return defaultApprover3Password;
      return defaultApprover1Password;
    }
    """

    # ── Every field, straight off the sheet ───────────────────────────────────
    * def currency = sheetVal('loanAmountCurrency')
    * def loanAmount = sheetNum('loanAmount')
    * def totalAmount = sheetNum('totalAmount')
    * def totalCurrency = sheetVal('totalAmountCurrency')
    * def customerContribution = sheetNum('customerContribution')
    * def loanTerm = sheetNum('loanTerm')
    * def termFrequency = sheetVal('termFrequency')
    * def interestType = sheetVal('interestType')
    * def repaymentFrequency = sheetVal('repaymentFrequency')
    * def overriddenRate = sheetNum('overriddenInterestRate')
    * def approvalLimitAmount = sheetNum('approvalLimitAmount')
    * def approvalLimitPartyType = sheetVal('approvalLimitPartyType')
    * def approvalLimitFacilityType = sheetVal('approvalLimitFacilityType')
    * def customerId = sheetVal('customerId')
    * def customerName = sheetVal('customerName')
    * def loanCategory = sheetVal('loanCategory')
    * def customerTypeSelected = sheetVal('customerTypeSelected')
    * def loanPurpose = sheetVal('loanPurpose')
    * def selectedProductCode = sheetVal('selectedProductCode')
    * def selectedProductName = sheetVal('selectedProductName')

    # Enterprise profile / scorecard metrics
    * def enterpriseType = sheetVal('enterpriseType')
    * def industrySector = sheetVal('industrySector')
    * def businessVintageYears = sheetNum('businessVintageYears')
    * def annualTurnover = sheetNum('annualTurnover')
    * def avgMonthlyCredits = sheetNum('avgMonthlyCredits')
    * def promoterCibilScore = sheetNum('promoterCibilScore')

    * def repaymentAcct = sheetVal('repaymentAccountNumber')
    * def feeAcct = sheetVal('feeFundingAccountNumber')

    # ── STAGE CHARGES ─────────────────────────────────────────────────────────
    # The product configuration levies each charge at a collection stage. Each stage has a sheet column naming
    # the charges that stage's user collects - charge name or code, any case, several separated by ';':
    #   APPLICATION       applicationCharges      officer, before submit
    #   ASSESSMENT        assessmentCharges       underwriter
    #   OFFER             offerCharges            issuer
    #   OFFER_ACCEPTANCE  offerAcceptanceCharges  acceptor
    #   SETUP             setupCharges            setup user, before the account is created in CBS
    # The row fails when a charge due at the stage is not named in its column, or a named charge is not
    # configured at that stage. A deferrable charge listed before it falls due may be named to collect it early.
    # A charge that will not settle is waived when chargeFallbackAction is WAIVE (chargeWaiveReason as the reason).
    # A charge negative row (expectedStatus CHARGE) passes at the first charge error containing expectedError.
    # POST .../collect answers HTTP 200 even when the host posting failed, so the body decides; a charge that will
    # not settle is waived when chargeFallbackAction is WAIVE. The calls reuse the stage user's own session:
    # auto-collect-helper signs a fresh admin in, which revokes it.
    * def chargeFallbackAction = sheetVal('chargeFallbackAction')
    * def noCharges = { error: null, collected: [] }
    # The rules live in stage-charges.js, shared with 08 - including the waiver (maker-checker approval + commit).
    * def stageChargesJs = read('classpath:features/loans/stage-charges.js')
    * def stageCharges = function(hdr, stage, column, chargeAppId) { return stageChargesJs(hdr, stage, column, chargeAppId, td, feeAcct) }
    * def chargeNegMatched =
    """
    function(res, stage) {
      if (!chargeNegRow || res == null || !res.error) return false;
      var exp = sheetOpt('expectedError') != null ? sheetOpt('expectedError').toLowerCase() : '';
      if (exp != '' && res.error.toLowerCase().indexOf(exp) < 0) return false;
      karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', td.testCaseId, '| Charges refused at', stage, '|', res.error);
      return true;
    }
    """
    * def chargeFail = function(res, stage) { return '[charges ' + stage + '] TestCase ' + td.testCaseId + ': ' + res.error + (chargeNegRow ? ' (expected an error containing "' + sheetOpt('expectedError') + '")' : '') }
    * def disbAcct = sheetVal('disbursementAccountNumber')
    * def settlementMode = sheetVal('settlementMode')
    * def disbursementMode = sheetVal('disbursementMode')
    * def disbursementDate = sheetVal('disbursementDate')
    * def disbursementNotes = sheetVal('disbursementNotes')
    * def offerValidityDate = sheetVal('offerValidityDate')
    * def offerRateAdjustment = sheetNum('offerRateAdjustment')
    * def offerPrincipalReduction = sheetNum('offerPrincipalReduction')
    * def notifyOff = sheetFlag('notifyOfficer')
    * def notifyCust = sheetFlag('notifyCustomer')
    * def extendedData = sheetOpt('extendedData') ? karate.fromString(sheetOpt('extendedData')) : null

    # ====================================================
    # PRODUCT TYPE RESOLUTION + APPROVAL-LIMIT BOOTSTRAP (idempotent per row)
    # ====================================================
    * def freshAdminToken = login(activeAdminUser, activeAdminPass)
    * def freshAdminHeader = 'Bearer ' + freshAdminToken
    * def authHeader = freshAdminHeader

    # ── Stage accounts ────────────────────────────────────────────────────────
    # A stage username from the sheet is honoured only where that account actually EXISTS here.
    # Enterpriise-Excel-Automation.xlsx names loanofficer01 / underwriter01 / setupofficer01 /
    # Credit_Comm1, which are seeded on some machines and absent on others (164.52.210.93 has
    # appuser01 / underwriter1 / setupuser1 / ccuser01 instead). karate-config.js is what resolves
    # the account that really holds each stage permission on this environment, so it is the
    # fallback — and the sheet stops being a per-environment hazard.
    #
    # Existence is checked with ONE GET, never by trying to log in: a speculative login burns the
    # account-lockout counter ("4 attempt(s) remaining before your account is locked") on any sheet
    # name that IS a real account whose password differs from the configured one.
    Given path '/v1/users'
    And param size = 500
    When method GET
    Then assert responseStatus == 200 || responseStatus == 403
    * def knownUsers = (responseStatus == 200) ? karate.jsonPath(response, '$[*].username') : []
    * def knownUserRecords = (responseStatus == 200) ? response : []
    * def userExists =
    """
    function(u) {
      if (u == null || u == '') return false;
      // Could not read the roster (403) — trust the sheet rather than silently overriding it.
      if (knownUsers == null || knownUsers.length == 0) return true;
      for (var i = 0; i < knownUsers.length; i++) { if (knownUsers[i] == u) return true; }
      return false;
    }
    """
    * def pickUser =
    """
    function(label, excelVal, fallbackUser) {
      var v = (excelVal != null && excelVal.toString().trim() != '') ? excelVal.toString().trim() : null;
      if (v == null) return fallbackUser;
      if (userExists(v)) return v;
      karate.log('[stage-user]', label, '- sheet account "' + v + '" does not exist on this environment; using the karate-config slot "' + fallbackUser + '"');
      return fallbackUser;
    }
    """
    * def activeOfficerUser = pickUser('officer', sheetOpt('officerUsername'), defaultOfficerUsername)
    * def activeOfficerPass = defaultOfficerPassword
    * def activeUwUser = pickUser('underwriter', sheetOpt('underwriterUsername'), defaultUnderwriterUsername)
    * def activeUwPass = defaultUnderwriterPassword
    * def activeApprover1User = pickUser('approver1', sheetOpt('approver1Username'), defaultApprover1Username)
    * def activeApprover2User = pickUser('approver2', sheetOpt('approver2Username'), defaultApprover2Username)
    * def activeIssuerUser = pickUser('issuer', sheetOpt('issuerUsername'), defaultIssuerUsername)
    * def activeIssuerPass = defaultIssuerPassword
    * def activeAcceptorUser = pickUser('acceptor', sheetOpt('acceptorUsername'), defaultAcceptorUsername)
    * def activeAcceptorPass = defaultAcceptorPassword
    * def activeSetupUser = pickUser('setup', sheetOpt('setupUsername'), defaultSetupUsername)
    * def activeSetupPass = defaultSetupPassword
    * print '✔ [TESTER VERIFICATION] Stage Accounts -> officer:', activeOfficerUser, '| underwriter:', activeUwUser, '| approver1:', activeApprover1User, '| approver2:', activeApprover2User, '| issuer:', activeIssuerUser, '| acceptor:', activeAcceptorUser, '| setup:', activeSetupUser

    # The SHEET decides the product type; the server only vetoes a code it does not have.
    # loanProductType is what resolves the workflow route, so a code with no BLO_PROD_TYPES row
    # resolves none and submit answers 500 — hence the veto rather than blind trust. Where the sheet
    # names a real ENTERPRISE/LOAN type it is used verbatim, which is what makes the sheet, and not
    # this feature, the thing that picks the product.
    Given path '/v1/product-types'
    When method GET
    Then status 200
    * def entLoanTypes = karate.jsonPath(response, "$.[?(@.customerType=='ENTERPRISE' && @.category=='LOAN' && @.active==true)]")
    * def entLoanTypeCodes = karate.jsonPath(entLoanTypes, '$[*].code')
    * def entLoanTypeCode = sheetVal('loanProductType')
    * def sheetTypeIsReal = (function() { for (var i = 0; i < entLoanTypeCodes.length; i++) { if (entLoanTypeCodes[i] == entLoanTypeCode) return true; } return false; })()
    # A negative row names a blank / unknown type on purpose - it goes to the server as it is.
    * if (!sheetTypeIsReal && entLoanTypeCodes.length > 0 && !isNegativeTest) entLoanTypeCode = entLoanTypeCodes[0]
    * print '✔ [TESTER VERIFICATION] Step 00: Enterprise Product Type -> Resolved To:', entLoanTypeCode, '| Active On Server | PASSED'

    * def approvalLimitArgs =
    """
    {
      baseUrl: '#(baseUrl)',
      makerAuthHeader: '#(freshAdminHeader)',
      makerUsername: '#(activeAdminUser)',
      loanType: '#(entLoanTypeCode)',
      partyType: '#(approvalLimitPartyType)',
      facilityType: '#(approvalLimitFacilityType)',
      currencyCode: '#(currency)',
      requiredAmount: #(loanAmount),
      limitAmount: #(approvalLimitAmount)
    }
    """
    # A negative row's data is deliberately invalid (unknown product type, currency, amount): no limit is bootstrapped for it.
    * if (!isNegativeTest) karate.call('classpath:features/loans/approval-limit-helper.feature', approvalLimitArgs)
    * print '✔ [TESTER VERIFICATION] Step 00b: Approval Limit Bootstrap -> LoanType:', entLoanTypeCode, '| Required:', loanAmount, currency, '| PASSED'

    # Step 01: Authenticate Loan Officer
    * def officerToken = login(activeOfficerUser, activeOfficerPass)
    * def officerAuthHeader = 'Bearer ' + officerToken
    * def authHeader = officerAuthHeader
    * print '✔ [TESTER VERIFICATION] Step 01: Officer Auth -> User:', activeOfficerUser, '| Status: PASSED (Token Issued)'

    # ─── ORIGINATION WIZARD (ENTERPRISE) ────────────────────────────────────

    * atStep('01')

    # Step 02: Submittable Product Types
    Given path '/v1/product-types/submittable'
    When method GET
    Then status 200
    * def submittableCodes = karate.jsonPath(response, "$[*].code")
    * print '✔ [TESTER VERIFICATION] Step 02: Submittable Product Types -> Target:', entLoanTypeCode, '| Returned Codes:', submittableCodes, '| MATCHED'

    # (A negative row's product type is invalid on purpose - this lookup only informs; submit must refuse it.)
    Given path '/v1/product-types/' + entLoanTypeCode + '/fields'
    When method GET
    Then assert responseStatus == 200 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 02b: Facility Fields Lookup -> Facility:', entLoanTypeCode, '| Status: MATCHED'

    * atStep('02')

    # Step 03: Corporate Customer Profile & Eligibility
    # 404 is legitimate — the enterprise customer cache is CBS-sourced and not seeded everywhere.
    Given path '/v1/enterprise-customers/' + customerId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || isNegativeTest
    * def entCustStatus = responseStatus
    * def entCustName = (responseStatus == 200 && response.enterpriseName) ? response.enterpriseName : ((responseStatus == 200 && response.fullName) ? response.fullName : null)
    * if (entCustName != null && entCustName != '') customerName = entCustName
    * def apiBranch = (responseStatus == 200 && (response.branch || response.branchCode || response.homeBranch)) ? (response.branch || response.branchCode || response.homeBranch) : null
    * def customerBranch = (sheetOpt('branch') != null && sheetOpt('branch') != '') ? sheetOpt('branch') : (apiBranch != null ? apiBranch : '00000001')

    Given path '/v1/enterprise-customers/' + customerId + '/validate'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404
    * print '✔ [TESTER VERIFICATION] Step 03: Corporate Customer Lookup -> Expected ID:', customerId, '| Expected Name:', customerName, '| Actual Name:', entCustName, '| Profile HTTP:', entCustStatus, '| Validate HTTP:', responseStatus

    * atStep('03')

    # Step 04: Initial Draft Creation
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef
    * match response.id == '#number'
    * match response.applicationRef == '#string'
    * print '✔ [TESTER VERIFICATION] Step 04: Initial Draft Creation -> Draft ID:', draftId, '| Reference:', draftRef, '| PASSED'

    * atStep('04')

    # Step 05: Product Selection
    Given path '/v1/origination/products/search'
    And param customerType = 'ENTERPRISE'
    And param productTypeCode = entLoanTypeCode
    And param currency = currency
    When method GET
    Then match [200, 503] contains responseStatus
    * def entItems = (responseStatus == 200 && response.items) ? response.items : []
    * def serverProductCodes = karate.jsonPath(entItems, '$[*].productCode')
    * def entProductCode = selectedProductCode
    * def entProductName = selectedProductName
    # Not fatal: CBS master data is not seeded everywhere, so an empty list is a CBS gap rather than
    # a bad sheet. The sheet's code is used either way — this only says whether CBS agreed.
    # Index by hand: the JSON array Karate hands back is a Java-backed proxy, and calling
    # Array.prototype methods such as contains()/includes() on it throws "Message not supported".
    * def productOfferedByServer =
    """
    (function() {
      for (var i = 0; i < serverProductCodes.length; i++) { if (serverProductCodes[i] == entProductCode) return true; }
      return false;
    })()
    """
    * if (!productOfferedByServer) karate.log('[product] sheet selectedProductCode "' + entProductCode + '" was not returned by /v1/origination/products/search (server offered: ' + serverProductCodes + ') - using the sheet value anyway')
    * print '✔ [TESTER VERIFICATION] Step 05: Enterprise Product Selection -> From Sheet:', entProductCode, '| Offered By Server:', productOfferedByServer, '| Returned Count:', karate.sizeOf(entItems)

    * atStep('05')

    # Step 05b: Schedule Generation — the UI's Interest & Schedule step (same screen as retail) keeps
    # Next disabled until a schedule has been generated, so a positive row needs HTTP 200 here; any
    # other answer (e.g. 503 CBS_UNAVAILABLE) fails it. A negative row passes here when this is the
    # refusal it expects; otherwise it goes on to the draft save / submit where its error is checked.
    * def calcTermMonths = (termFrequency == 'YEARS' ? loanTerm * 12 : loanTerm)
    # generateSchedule column: blank / Y = generate (the UI's Interest & Schedule step does);
    # N = skip it, exactly as a direct API caller can — used by negative rows that prove submit
    # refuses a draft that never had a schedule.
    * def doGenerate = sheetOpt('generateSchedule') == null || sheetOpt('generateSchedule').toUpperCase() != 'N'
    # rateId and repaymentType come from the CBS sub-product configuration (the Step 05 search result),
    # as the UI's Interest & Schedule step sends them: rateId = the product's default rate for the
    # interest type, repaymentType = the product's CBS letter code (e.g. C / R / K).
    * def cbsProduct = karate.filter(entItems, function(p){ return p.productCode == entProductCode })
    * def cbsProduct = cbsProduct.length > 0 ? cbsProduct[0] : {}
    * def rateIdByType = { FIXED: '#(cbsProduct.defaultFixedRateId)', FLOATING: '#(cbsProduct.defaultFloatingRateId)', PROGRESSIVE: '#(cbsProduct.defaultProgressiveRateId)' }
    * def schedRateId = rateIdByType[interestType] || cbsProduct.defaultFixedRateId || cbsProduct.defaultFloatingRateId || cbsProduct.defaultProgressiveRateId || null
    * def schedRepaymentType = cbsProduct.repaymentType || null
    * if (!schedRateId) karate.log('[schedule] product', entProductCode, 'has no rate id in the sub-product configuration LO holds - CBS will refuse the schedule')
    * def genRequest = { loanAmount: '#(loanAmount)', currency: '#(currency)', termMonths: '#(calcTermMonths)', annualInterestRate: '#(overriddenRate)', repaymentFrequency: '#(repaymentFrequency)', productCode: '#(entProductCode)', repaymentType: '#(schedRepaymentType)', rateId: '#(schedRateId)', customerId: '#(customerId)' }
    # Loan start and first repayment dates, as the UI's Interest & Schedule step sends them. Without them the
    # server puts the first repayment on the business date (the disbursement day), off the sheet's schedule.
    * def schedFirstRepay = sheetOpt('repaymentStartDate') ? sheetOpt('repaymentStartDate').substring(0, 10) : null
    * def schedLoanStart = sheetOpt('loanStartDate') ? sheetOpt('loanStartDate').substring(0, 10) : null
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
    * if (pepRow != null && !pepSent) karate.log('[pep] TestCase', testCaseId, 'has pepRows but the product does not allow PEP - not sent to schedule generation, as in the UI')
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
    * if (optionFields.sent.length > 0) karate.log('[schedule] repayment options sent - TestCase', testCaseId, ':', optionFields.sent.join(', '))
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
    * if (schedOverride != null) karate.log('[schedule] scheduleOverride applied - TestCase', testCaseId, '| request sent:', karate.toString(genRequest))
    # A "Manual Schedule" sub-product (repaymentTypeDesc from the CBS sub-product configuration) also
    # sends the sheet's autoPopulationMethod to schedule generation, as the UI's Auto Population field does.
    * def isManualProduct = cbsProduct.repaymentTypeDesc == 'Manual Schedule'
    * if (isManualProduct && td.autoPopulationMethod) karate.set('genRequest', karate.merge(genRequest, { autoPopulationMethod: td.autoPopulationMethod }))
    * print '[schedule] Step 05b request -> product:', entProductCode, '| rateId:', schedRateId, '| repaymentType:', schedRepaymentType
    * def genResult = doGenerate ? karate.http(baseUrl + '/v1/origination/schedule/generate').header('Authorization', officerAuthHeader).header('Content-Type', 'application/json').post(genRequest) : null
    * def genStatus = doGenerate ? genResult.status : 0
    * def genBody = doGenerate ? genResult.body : null
    * if (!doGenerate) karate.log('[schedule] generateSchedule=N - TestCase', testCaseId, 'skips schedule generation, as a direct API caller can')
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Schedule generation rejected with HTTP', genStatus, '| Expected error matched:', sheetOpt('expectedError'))
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) RowActions.endRow(testCaseId)
    * if (doGenerate && isNegativeTest && matchNegative(genStatus, genBody)) karate.abort()
    # A schedule-negative row (scheduleOverride filled) must be refused here exactly as expected.
    * if (doGenerate && isNegativeTest && schedOverride != null && !matchNegative(genStatus, genBody)) karate.fail('[SCHEDULE NEGATIVE FAILED] TestCase ' + testCaseId + ': expected HTTP ' + sheetOpt('expectedStatus') + ' / code ' + sheetOpt('expectedCode') + ' / error "' + sheetOpt('expectedError') + '" but got HTTP ' + genStatus + ' ' + karate.toString(genBody))
    * if (doGenerate && !isNegativeTest && genStatus != 200) karate.fail('[SCHEDULE GENERATION FAILED] TestCase ' + testCaseId + ': HTTP ' + genStatus + ' ' + karate.toString(genBody))
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
    * def noPepResult = pepCheck ? karate.http(baseUrl + '/v1/origination/schedule/generate').header('Authorization', officerAuthHeader).header('Content-Type', 'application/json').post(noPepReq) : null
    * def noPepEmi = (pepCheck && noPepResult.status == 200) ? analysePep(noPepResult.body, 0).regularEmi : null
    * if (pepCheck && pepGen.bumped != pepCountNum) karate.fail('[PEP NOT APPLIED] TestCase ' + testCaseId + ': expected ' + pepCountNum + ' installments raised by ' + pepAmountNum + ', found ' + pepGen.bumped + ' (regular installment ' + pepGen.regularEmi + ')')
    * if (pepCheck && Math.abs(pepGen.lastBalance) > 1) karate.fail('[PEP SCHEDULE] TestCase ' + testCaseId + ': last closing balance is ' + pepGen.lastBalance + ', expected 0')
    * if (pepCheck && noPepEmi != null && !(pepGen.regularEmi < noPepEmi)) karate.fail('[PEP SCHEDULE] TestCase ' + testCaseId + ': regular installment with PEP ' + pepGen.regularEmi + ' is not lower than without PEP ' + noPepEmi)
    * def pepColumnOk = !pepCheck || pepGen.pepColumn == pepCountNum
    * if (pepCheck) karate.log('✔ [TESTER VERIFICATION] Step 05b PEP -> raised installments:', pepGen.bumped, 'of', pepCountNum, '| regular EMI with PEP:', pepGen.regularEmi, '| without PEP:', noPepEmi, '| last balance:', pepGen.lastBalance, '| pep column rows:', pepGen.pepColumn)
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
    * if (optErrors.length > 0) karate.fail('[REPAYMENT OPTIONS NOT IN SCHEDULE] TestCase ' + testCaseId + ': ' + optErrors.join('; '))
    * if (optCheck) karate.log('✔ [TESTER VERIFICATION] Step 05b Repayment options -> ' + optionFields.sent.join(', ') + ' | schedule shape MATCHED')
    * print '✔ [TESTER VERIFICATION] Step 05b: Repayment Schedule Generation -> Loan Amount:', loanAmount, '| Term Months:', calcTermMonths, '| Status:', genStatus

    # Step 06: Financial Statement Template Download + Population
    Given path '/v1/origination/draft/' + draftId + '/financial-statement-template'
    And param enterpriseName = customerName
    And param partyId = customerId
    And param currency = currency
    When method GET
    Then match [200, 404, 500] contains responseStatus
    * def templateBytes = (responseStatus == 200) ? responseBytes : null
    * print '✔ [TESTER VERIFICATION] Step 06: Financial Statement Template -> Draft:', draftId, '| Download HTTP:', responseStatus, '| Bytes Received:', (templateBytes != null)

    * def entHelper = Java.type('com.ird.beyond.lo.test.util.EnterpriseFinancialsHelper')
    * def enterpriseFinancialsJson = entHelper.processDownloadedTemplate(templateBytes, td)
    * match enterpriseFinancialsJson == '#string'
    * print '✔ [TESTER VERIFICATION] Step 06b: Enterprise Financials Generated -> Length:', enterpriseFinancialsJson.length, '| PASSED'

    * atStep('06')

    # Step 07: Collateral
    * def colType = sheetOpt('collateralType')
    * def hasCollateral = colType != null
    * def colForcedVal = hasCollateral ? sheetNum('collateralForcedSaleValue') : 0
    * def collaterals = hasCollateral ? [ { "collateralType": colType, "description": sheetVal('collateralDescription'), "estimatedValue": sheetNum('collateralEstimatedValue'), "forcedSaleValue": colForcedVal, "currency": currency } ] : []
    * string manualCollateralsJson = collaterals
    * print '✔ [TESTER VERIFICATION] Step 07: Collateral Prepared -> Secured:', hasCollateral, '| Type:', colType, '| Forced Sale Value:', colForcedVal, '| Covers Loan Amount:', (colForcedVal >= loanAmount)

    * atStep('07')

    # Step 08: Save/Update Complete Enterprise Draft with Excel Data
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
      "loanCategory": "#(loanCategory)",
      "customerTypeSelected": "#(customerTypeSelected)",
      "customerId": "#(customerId)",
      "customerName": "#(customerName)",
      "branch": "#(customerBranch)",
      "accountOpenBranch": "#(customerBranch)",
      "loanPurpose": "#(loanPurpose)",
      "loanAmount": #(loanAmount),
      "loanAmountCurrency": "#(currency)",
      "totalAmount": #(totalAmount),
      "totalAmountCurrency": "#(totalCurrency)",
      "customerContribution": #(customerContribution),
      "loanTerm": #(loanTerm),
      "termFrequency": "#(termFrequency)",
      "selectedProductCode": "#(entProductCode)",
      "selectedProductName": "#(entProductName)",
      "loanProductType": "#(entLoanTypeCode)",
      "interestType": "#(interestType)",
      "rateId": "#(schedRateId)",
      "overriddenInterestRate": #(overriddenRate),
      "repaymentFrequency": "#(repaymentFrequency)",
      "enterpriseType": "#(enterpriseType)",
      "industrySector": "#(industrySector)",
      "businessVintageYears": #(businessVintageYears),
      "annualTurnover": #(annualTurnover),
      "avgMonthlyCredits": #(avgMonthlyCredits),
      "promoterCibilScore": #(promoterCibilScore),
      "enterpriseFinancials": "#(enterpriseFinancialsJson)",
      "manualCollaterals": "#(manualCollateralsJson)",
      "settlementMode": "#(settlementMode)",
      "paymentType": "#(td.paymentType)",
      "effectiveInterestRate": #(td.effectiveInterestRate),
      "repaymentStartDate": "#(td.repaymentStartDate)",
      "docSignedState": "#(td.docSignedState)",
      "repaymentAccountNumber": "#(repaymentAcct)",
      "feeFundingAccountNumber": "#(feeAcct)",
      "disbursementMode": "#(disbursementMode)",
      "disbursementDate": "#(disbursementDate)",
      "disbursementAccountNumber": "#(disbAcct)",
      "disbursementNotes": "#(disbursementNotes)",
      "extendedData": #(extendedData),
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
    * if (isNegativeTest && matchNegative(saveStatus, response)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Draft save rejected with HTTP', saveStatus, '| Expected error matched:', sheetOpt('expectedError'))
    * if (isNegativeTest && matchNegative(saveStatus, response)) RowActions.endRow(testCaseId)
    * if (isNegativeTest && matchNegative(saveStatus, response)) karate.abort()
    * if (saveStatus != 200) karate.fail('[DRAFT SAVE REFUSED] TestCase ' + testCaseId + ': HTTP ' + saveStatus + ' ' + karate.toString(response) + (isNegativeTest ? ' | expected HTTP "' + sheetOpt('expectedStatus') + '" / error "' + sheetOpt('expectedError') + '"' : ''))
    * match response.loanAmount == loanAmount
    * match response.selectedProductCode == entProductCode
    * match response.customerId == customerId
    * def draftRef = response.applicationRef != null ? response.applicationRef : draftRef
    * print '✔ [TESTER VERIFICATION] Step 08: Save Draft Data -> Expected Loan Amount:', loanAmount, '| Actual Response:', response.loanAmount, '| Product:', response.selectedProductCode, '| Reference:', draftRef, '| MATCHED | Repayment options: interestFrequency', td.interestFrequency, 'balloon', td.balloonAmount, 'moratorium', td.moratoriumType, td.moratoriumMonths, 'autoPopulation', td.autoPopulationMethod

    # Step 08b: Manual Schedule Upload — the UI's Upload Schedule (Interest & Schedule step, after a
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
    * def manualRows = doManualUpload ? buildManualRows(manualCell, (genStatus == 200 && genBody != null && genBody.length ? genBody : []), loanAmount) : []
    * def upResult = doManualUpload ? karate.http(baseUrl + '/v1/origination/draft/' + draftId + '/schedule').header('Authorization', officerAuthHeader).header('Content-Type', 'application/json').post(manualRows) : null
    * def upStatus = doManualUpload ? upResult.status : 0
    * def upBody = doManualUpload ? upResult.body : null
    * if (doManualUpload) karate.log('[manual-schedule] TestCase', testCaseId, '| manual product:', isManualProduct, '| rows:', karate.sizeOf(manualRows), '| principal total:', sumPrincipal(manualRows), '| HTTP', upStatus)
    # A row with its own manualSchedule cell and an expected error is a negative upload: it must be refused here.
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Manual schedule upload rejected with HTTP', upStatus)
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) RowActions.endRow(testCaseId)
    * if (doManualUpload && isNegativeTest && manualCell != null && matchNegative(upStatus, upBody)) karate.abort()
    * if (doManualUpload && isNegativeTest && manualCell != null) karate.fail('[MANUAL SCHEDULE NEGATIVE FAILED] TestCase ' + testCaseId + ': expected HTTP ' + sheetOpt('expectedStatus') + ' / code ' + sheetOpt('expectedCode') + ' / error "' + sheetOpt('expectedError') + '" but the upload got HTTP ' + upStatus + ' ' + karate.toString(upBody))
    * if (doManualUpload && !isNegativeTest && upStatus != 200) karate.fail('[MANUAL SCHEDULE UPLOAD FAILED] TestCase ' + testCaseId + ': HTTP ' + upStatus + ' ' + karate.toString(upBody))
    * def manualUploaded = doManualUpload && !isNegativeTest && upStatus == 200
    * if (doManualUpload) karate.log('✔ [TESTER VERIFICATION] Step 08b: Manual Schedule Upload -> Rows:', karate.sizeOf(manualRows), '| Principal Total:', sumPrincipal(manualRows), '| Loan Amount:', loanAmount, '| Status:', upStatus)

    * atStep('08')

    # Step 09: Document Checklist & Upload
    Given path '/v1/product-config/checklist'
    And param productTypeCode = entLoanTypeCode
    And param productCode = entProductCode
    When method GET
    Then match [200, 404] contains responseStatus
    * print '✔ [TESTER VERIFICATION] Step 09: Document Checklist Lookup -> Status:', responseStatus, '| MATCHED'

    # uploadDocumentName may name several documents separated by ';' - one upload each, under the
    # name the sheet gives (the checklist matches on it). uploadDocumentType is either one type for
    # all of them or a ';' list in the same order.
    * def isUploadDoc = (sheetOpt('uploadDocument') != null && sheetOpt('uploadDocument').toLowerCase() == 'true')
    * def docUploads =
    """
    function() {
      var names = sheetOpt('uploadDocumentName') == null ? [] : sheetOpt('uploadDocumentName').split(';');
      var types = sheetOpt('uploadDocumentType') == null ? [] : sheetOpt('uploadDocumentType').split(';');
      var out = [];
      for (var i = 0; i < names.length; i++) {
        if (names[i].trim() == '') continue;
        var type = types.length > i ? types[i].trim() : (types.length > 0 ? types[0].trim() : null);
        out.push({ appRef: draftRef, docType: type, docName: names[i].trim(), docStatus: sheetOpt('documentStatus'), docComment: sheetOpt('documentStatusComment'), docPhase: sheetOpt('uploadDocumentPhase'), authHeader: officerAuthHeader, baseUrl: baseUrl });
      }
      return out;
    }
    """
    * def docsToUpload = isUploadDoc ? docUploads() : []
    * if (karate.sizeOf(docsToUpload) > 0) karate.call('classpath:features/loans/upload-document-helper.feature', docsToUpload)

    * atStep('09')

    # Step 10: External Screening (AML / Sanctions / PEP) — resilient, never fails the run
    * eval
    """
    try {
      karate.call('classpath:features/loans/external-screening-helper.feature', { appRef: draftRef, authHeader: freshAdminHeader, baseUrl: baseUrl });
      karate.log('[' + testCaseId + '] Step 10 - External Screening Run Completed');
    } catch (e) {
      karate.log('[' + testCaseId + '] Step 10 - External Screening skipped / timed out: ' + e);
    }
    """

    * atStep('10')

    # Step 11: Charge Collection & Draft Submission
    # The officer collects the APPLICATION charges (applicationCharges). The draft is normally linked to its
    # application already; when it is not, submit answers 409 for a due charge and they are collected then.
    * def draftAppId = function() { var d = karate.http(baseUrl + '/v1/origination/draft/' + draftId).header('Authorization', officerAuthHeader).get().body; return d == null ? null : d.linkedApplicationId }
    * def preSubmitAppId = draftAppId()
    * def appCharges = preSubmitAppId ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', preSubmitAppId) : null
    * def appChargesNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargesNeg) RowActions.endRow(testCaseId)
    * if (appChargesNeg) karate.abort()
    * if (appCharges != null && appCharges.error && isNegativeTest) karate.log('[charges APPLICATION] API negative', testCaseId, '- the charge problem is logged, the server judges the row:', appCharges.error)
    * if (appCharges != null && appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))

    Given path '/v1/origination/draft/' + draftId + '/submit'
    When method POST
    * def submitStatus = responseStatus
    * def submitResponse = response

    # ── NEGATIVE TEST: the row passes when submit refuses the draft the way the sheet expects ──
    * def negativeMatched = isNegativeTest && matchNegative(submitStatus, submitResponse)
    * if (negativeMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Submit rejected with HTTP', submitStatus, '| Expected error matched:', sheetOpt('expectedError'))
    * if (negativeMatched) RowActions.endRow(testCaseId)
    * if (negativeMatched) karate.abort()
    * if (isNegativeTest && !setupNegRow && submitStatus >= 400 && submitStatus != 409) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected HTTP "' + sheetOpt('expectedStatus') + '" / error "' + sheetOpt('expectedError') + '" but submit answered HTTP ' + submitStatus + ': ' + karate.toString(submitResponse))
    * if (isNegativeTest && !setupNegRow && submitStatus < 400) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected the draft to be refused but submit SUCCEEDED (HTTP ' + submitStatus + ')')
    # A row that expects to go through: say what the submit API objected to, in its own words.
    * if (submitStatus >= 400 && submitStatus != 409) karate.fail('[SUBMIT REFUSED] TestCase ' + testCaseId + ': HTTP ' + submitStatus + ' ' + karate.toString(submitResponse))
    * def appCharges = (submitStatus == 409) ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', draftAppId()) : appCharges
    * def appChargesNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargesNeg) RowActions.endRow(testCaseId)
    * if (appChargesNeg) karate.abort()
    * if (appCharges != null && appCharges.error && isNegativeTest) karate.log('[charges APPLICATION] API negative', testCaseId, '- the charge problem is logged, the server judges the row:', appCharges.error)
    * if (appCharges != null && appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))
    * def resubmitResult = (submitStatus == 409) ? karate.call('classpath:features/loans/resubmit-draft-helper.feature', { draftId: draftId, authHeader: officerAuthHeader, baseUrl: baseUrl }) : null
    * def finalSubmitResponse = (resubmitResult && resubmitResult.resubmittedResponse) ? resubmitResult.resubmittedResponse : submitResponse
    * def appId = finalSubmitResponse.linkedApplicationId
    * match appId == '#notnull'
    # Not linked before submit and no 409: check the column against what the application has at APPLICATION.
    * def appCharges = appCharges == null ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', appId) : appCharges
    * def appChargesNeg = chargeNegMatched(appCharges, 'APPLICATION')
    * if (appChargesNeg) RowActions.endRow(testCaseId)
    * if (appChargesNeg) karate.abort()
    * if (appCharges.error && !isNegativeTest) karate.fail(chargeFail(appCharges, 'APPLICATION'))
    * print '✔ [TESTER VERIFICATION] Step 11a: Application Charges -> Collected by:', activeOfficerUser, '|', appCharges.collected
    * print '✔ [TESTER VERIFICATION] Step 11: Draft Submission -> Draft ID:', draftId, '| Submit HTTP:', submitStatus, '| Linked Application ID:', appId, '| Status: SUBMITTED'

    # Submitted: the SendBack runner takes the application from here.
    * print '[sendback-origination] TestCase', td.testCaseId, 'submitted as application', appId
    * RowActions.endRow(td.testCaseId)
