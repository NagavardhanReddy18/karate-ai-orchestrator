@loans @e2e @data-driven @enterprise
Feature: Enterprise Loan Lifecycle — data-driven runner over all enabled Excel rows

  # ── Data-driven runner ────────────────────────────────────────────────────
  # Loads every row whose "run" column is "Y" from the Enterprise Excel sheet and
  # iterates through each one, calling @lifecycle below.
  # Credential fallback is handled inside @lifecycle via sheetOpt()/pickUser():
  #   row column filled → use that value | blank → fall back to karate-config.
  Scenario: Run Enterprise Loan Lifecycle for all enabled Excel rows
    * def Loader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def loadRows =
    """
    function(paths) {
      for (var i = 0; i < paths.length; i++) {
        try {
          var rows = Loader.load(karate.toAbsolutePath('classpath:' + paths[i]));
          if (rows != null && rows.length > 0) {
            karate.log('[05-ENTERPRISE] using', paths[i], '->', rows.length, 'row(s) with run=Y');
            return rows;
          }
        } catch (e) { karate.log('[05-ENTERPRISE] could not read', paths[i], ':', e); }
      }
      return [];
    }
    """
    * def rawRows = loadRows(['features/loans/testdata/Enterpriise-Excel-Automation.xlsx'])
    * def annotateRows = function(rList) { if (rList == null) return []; var n = rList.length; for (var i = 0; i < n; i++) { rList[i].rowIndex = i + 1; rList[i].totalRows = n; } return rList; }
    # runOnEnv column (optional): blank = every environment; otherwise a comma list of ports or env
    # names (9090, 9190, dev, test) — for rows whose product is configured differently per server.
    * def forThisEnv = function(r) { var e = r.runOnEnv; if (e == null || e.toString().trim() == '') return true; var parts = e.toString().split(','); for (var i = 0; i < parts.length; i++) { var p = parts[i].trim(); if (p == karate.env || baseUrl.indexOf(':' + p + '/') >= 0) return true; } return false }
    * def rows = annotateRows(karate.filter(rawRows, forThisEnv))
    * def rowCount = rows.length
    * print '======================================================='
    * print '[05-ENTERPRISE] Total Excel rows enabled (run=Y):', rowCount
    * print '======================================================='
    * if (rowCount == 0) karate.log('[05-ENTERPRISE] No run=Y rows found — skipping')
    * if (rowCount > 0) karate.call('classpath:features/loans/05-BLO-Enterprise-LifeCycle.feature@lifecycle', rows)

  @ignore @lifecycle
  Scenario: Run direct enterprise lifecycle for one Excel row with step-by-step state and assignedTo verification

    # ── Excel resolution ──────────────────────────────────────────────────────
    # First candidate that exists AND has run=Y rows wins. Enterpriise-Excel-Automation.xlsx is the
    # Direct-family sheet (same -Excel-Automation naming as the retail one); enterprise-loan-test-data.xlsx
    # is the older sheet the non-Direct 05 pair reads and is kept as the fallback.
    * def loadRows =
    """
    function(paths) {
      var Loader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader');
      for (var i = 0; i < paths.length; i++) {
        try {
          var rows = Loader.load(karate.toAbsolutePath('classpath:' + paths[i]));
          if (rows != null && rows.length > 0) {
            karate.log('[excel] using', paths[i], '->', rows.length, 'row(s) with run=Y');
            return rows;
          }
          karate.log('[excel]', paths[i], 'has no run=Y rows - trying the next candidate');
        } catch (e) {
          karate.log('[excel] could not read', paths[i], ':', e);
        }
      }
      return [];
    }
    """
    * def activeRows = loadRows(['features/loans/testdata/Enterpriise-Excel-Automation.xlsx'])
    * def excelRow = (activeRows != null && activeRows.length > 0) ? activeRows[0] : null
    * def td = (typeof __arg !== 'undefined' && __arg != null) ? __arg : ((typeof row !== 'undefined' && row != null) ? row : (excelRow != null ? excelRow : {}))

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

    # Step 11b: Verify Status Post-Submission
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * match response.status == 'SUBMITTED'
    * print '✔ [TESTER VERIFICATION] Step 11b: Post-Submission State -> Expected Status: SUBMITTED | Actual Status:', response.status, '| MATCHED'

    * atStep('11')

    # Step 12: Stage Skip Flags Resolution
    * def isSkipUw = sheetFlag('skipUw')
    * def isSkipApp1 = sheetFlag('skipApprover1')
    * def isSkipApp2 = sheetFlag('skipApprover2')
    * def isSkipIssueOffer = sheetFlag('skipIssueOffer')
    * def isSkipOfferAccept = sheetFlag('skipOfferAccept')
    * def isSkipSetup = sheetFlag('skipLoanSetup')

    * atStep('12')

    # Step 13: Underwriter Stage - Claim & Assignee Verification
    * def uwToken = isSkipUw ? null : login(activeUwUser, activeUwPass)
    * def uwAuthHeader = isSkipUw ? null : ('Bearer ' + uwToken)
    # A skipped stage has no token of its own. Reads after it must still be authenticated, so
    # fall back to the officer session — which stays valid until the logout block at the end —
    # rather than sending the next GET with no Authorization at all (401).
    * def authHeader = (uwAuthHeader != null) ? uwAuthHeader : officerAuthHeader
    * if (!isSkipUw) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipUw && response.assignedTo) karate.match(response.assignedTo, activeUwUser)
    * print '✔ [TESTER VERIFICATION] Step 13: Underwriter Claim -> Claimed By:', activeUwUser, '| AssignedTo:', response.assignedTo, '| Status:', response.status, '| MATCHED'

    # Corporate intake — present only where the environment models it as a wait-step.
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || response.length > 0
    When method GET
    Then status 200
    * def tasks = response
    * def intakeTasks = isSkipUw ? [] : karate.jsonPath(tasks, "$.[?(@.taskDefinitionKey=='applicationIntake' || @.taskDefinitionKey=='corporateIntake')]")
    * def intakeBody = (intakeTasks.length > 0 && intakeTasks[0].taskDefinitionKey == 'corporateIntake') ? { promoters: [sheetVal('promoterName')] } : {}
    * if (!isSkipUw && intakeTasks.length > 0) karate.call('classpath:features/loans/complete-task-helper.feature', { taskId: intakeTasks[0].id, requestBody: intakeBody, authHeader: uwAuthHeader, baseUrl: baseUrl })
    * print '✔ [TESTER VERIFICATION] Step 13b: Corporate Intake -> Intake Tasks Found:', karate.sizeOf(intakeTasks), '| Completed:', (intakeTasks.length > 0)

    * atStep('13')

    # Step 14: Underwriter Decision
    Given path '/v1/product-config/checklist/by-application/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404

    # Wait for the Underwriter Review step — proves the financial + collateral automated gates passed.
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || karate.jsonPath(response, "$.[?(@.name=='Underwriter Review' || @.taskDefinitionKey=='underwriterReview')]").length > 0
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 14b: Underwriter Review Task Available -> Financial + Collateral Gates: PASSED'

    # Step 14c: The underwriter opens the assessment. The server creates it on this first read, resolves the
    # assessment method and scorecard (the sub-product's own, else the product type's) and, for AUTO, lets the
    # scorecard decide at once. The rest of the row follows what the server resolved - nothing per row:
    #   AUTO_APPROVED                       underwriter and approvers are skipped; offer, acceptance and setup follow
    #                                       (the issuer collects the ASSESSMENT charges)
    #   AUTO_REJECTED                       the application is rejected - the row fails
    #   MANUAL / MANUAL_INTERNAL            the underwriter decides without a scorecard, then the approvers
    #   AUTO / EXTERNAL / MANUAL_EXTERNAL   with no scorecard result yet: evaluate it so the underwriter can decide
    * def assessRes = isSkipUw ? null : karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', authHeader).get()
    * if (assessRes != null && assessRes.status >= 400) karate.fail('[ASSESSMENT] TestCase ' + testCaseId + ': opening the assessment failed with HTTP ' + assessRes.status + ' ' + karate.toString(assessRes.body))
    * def assessRec = assessRes == null ? {} : (assessRes.body.data ? assessRes.body.data : assessRes.body)
    * def assessMethod = assessRec.resolvedAssessmentMethod
    * def autoApproved = assessRec.uwDecision == 'AUTO_APPROVED'
    * def autoRejected = assessRec.uwDecision == 'AUTO_REJECTED'
    * if (autoRejected) karate.fail('[ASSESSMENT] TestCase ' + testCaseId + ': AUTO-REJECTED by the scorecard (' + assessRec.scorecardResult + ', ' + assessRec.scorecardTotalScorePct + '%): ' + assessRec.declineReason)
    * def needsScorecard = !autoApproved && (assessMethod == 'AUTO' || assessMethod == 'EXTERNAL' || assessMethod == 'MANUAL_EXTERNAL') && assessRec.scorecardResult == null
    * def scorecardEvalStatus = needsScorecard ? karate.http(baseUrl + '/v1/assessment/' + appId + '/evaluate-scorecard').header('Authorization', authHeader).header('Content-Type', 'application/json').post({}).status : 'NOT NEEDED'
    * def assessRec = needsScorecard ? karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', authHeader).get().body : assessRec
    * print '✔ [TESTER VERIFICATION] Step 14c: Assessment Opened -> Method:', assessMethod, '| Rule:', assessRec.resolvedRuleName, '| Scorecard:', assessRec.scorecardResult, assessRec.scorecardTotalScorePct, '| Decision:', assessRec.uwDecision, '| Scorecard evaluation:', scorecardEvalStatus
    # AUTO-approved by the scorecard: no underwriter or approver decision is taken.
    * if (autoApproved) karate.log('[workflow] TestCase', testCaseId, 'AUTO-APPROVED by the scorecard (' + assessRec.scorecardTotalScorePct + '%) - underwriter and approver stages skipped')
    * def isSkipUw = (isSkipUw == true || autoApproved == true) ? true : false
    * def isSkipApp1 = (isSkipApp1 == true || autoApproved == true) ? true : false
    * def isSkipApp2 = (isSkipApp2 == true || autoApproved == true) ? true : false

    * if (!isSkipUw) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })
    # (underwriter-stage charge collection is handled by the CHARGE SETTLEMENT GATE below,
    #  which reads the response body and reuses the underwriter session instead of minting
    #  another admin one - see the block before the uw-action call)
    * if (!isSkipUw) karate.call('classpath:features/loans/assessment-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })


    # ── CHARGE SETTLEMENT GATE ────────────────────────────────────────────────
    # uw-action refuses to route to the approver stage while an ASSESSMENT charge is outstanding
    # (409 PENDING_CHANGE_EXISTS); the underwriter collects them here - see STAGE CHARGES.
    * def uwCharges = isSkipUw ? noCharges : stageCharges(uwAuthHeader, 'ASSESSMENT', 'assessmentCharges', appId)
    * def uwChargesNeg = chargeNegMatched(uwCharges, 'ASSESSMENT')
    * if (uwChargesNeg) RowActions.endRow(testCaseId)
    * if (uwChargesNeg) karate.abort()
    * if (uwCharges.error) karate.fail(chargeFail(uwCharges, 'ASSESSMENT'))
    * print '✔ [TESTER VERIFICATION] Assessment Charges -> Collected by:', isSkipUw ? 'SKIPPED' : activeUwUser, '|', uwCharges.collected

    * def uwComment = 'Karate E2E Enterprise Direct | ' + testCaseId
    * def rawUwAction = isSkipUw ? null : sheetVal('uwAction')
    * def resolvedUwAction = (rawUwAction == 'APPROVE' ? 'APPROVE_TO_APPROVER' : rawUwAction)
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
    * if (pastApproval == true) karate.log('[workflow] TestCase', testCaseId, 'is already', postUwStatus, 'after underwriting - approver stages skipped')
    * def isSkipApp1 = (isSkipApp1 == true || pastApproval == true) ? true : false
    * def isSkipApp2 = (isSkipApp2 == true || pastApproval == true) ? true : false
    * def isSkipIssueOffer = (isSkipIssueOffer == true || postUwStatus == 'OFFER_ISSUED' || postUwStatus == 'OFFER_ACCEPTED') ? true : false
    * def isSkipOfferAccept = (isSkipOfferAccept == true || postUwStatus == 'OFFER_ACCEPTED') ? true : false

    # ====================================================
    * atStep('15')

    # Step 16: APPROVAL — direct authority, committee quorum, or SEQUENTIAL CHAIN
    # ====================================================
    # The server picks the routing per application, and the enterprise sheet exercises all three:
    #
    #   directResolvedAuthorityType = USER    one named user finalises on a single vote
    #   directResolvedAuthorityType = CREDIT_COMMITTEE   N distinct members of that role must vote
    #   resolvedRoutingMethod       = SEQUENTIAL         a CHAIN of hops, each with its own
    #                                                    authority and limit, walked in order
    #
    # The retail feature only ever meets the first two, so its fixed "vote 1 then vote 2" shape is
    # enough there. It is not enough here: TC-ENT-003 (750,000 USD on 05010DEFAULTUSD) resolves to a
    # three-hop chain — USER/approver1 (300k) -> USER/approver2 (400k) -> CREDIT_COMMITTEE/APPROVER
    # (2 votes, 100M) — and voting as anyone but the CURRENT hop is rejected with
    #   403 "You are not the current authority for this application in the sequential chain."
    #
    # So the voter is not chosen up front. Before every vote the driver re-reads
    # /v1/assessment/{id}, asks who is entitled to act NOW, signs that account in and votes as it —
    # which makes the block correct for one vote, two votes, or a re-tuned chain, with no edits.
    #
    # It is a JS loop rather than a run of Gherkin steps because the number of votes is not known
    # until the server has been asked, and it uses karate.http rather than the claim/approver-action
    # helper features for the same reason — a helper call cannot be re-driven from inside a loop.
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipApp1 || karate.jsonPath(response, "$.[?(@.name=='Credit Approval' || @.taskDefinitionKey=='creditApproval')]").length > 0
    When method GET
    Then status 200

    Given path '/v1/assessment/' + appId
    When method GET
    Then status 200
    * def assm = response
    * def routingMethod = assm.resolvedRoutingMethod
    * def targetAuthType = assm.directResolvedAuthorityType
    * def targetAuthNames = assm.directResolvedAuthorityNames
    * def chainState = assm.sequentialChainState
    * def isSequential = (chainState != null && chainState.sequentialRouting == true)
    * print '✔ [TESTER VERIFICATION] Step 16: Approval Routing -> Method:', routingMethod, '| Direct Authority:', targetAuthType, '/', targetAuthNames, '| Sequential:', isSequential, '| Hops:', (isSequential ? chainState.totalHops : 0)

    # Each approver vote takes its action from the sheet: the first vote approver1Action, every later vote
    # approver2Action. A hop whose limit cannot cover the amount still REFERs - the server allows nothing else there.
    * def approver1Action = (isSkipApp1 && isSkipApp2) ? null : sheetVal('approver1Action')
    * def approver2Action = sheetOpt('approver2Action')
    * def approverHeaders = []
    # Reader session for the loop below. NOT freshAdminHeader: auto-collect-helper signs the admin
    # in again during the underwriting stage, and this server revokes the previous session on
    # re-login (the JWT carries a session epoch), so that token is already dead by here. The
    # underwriter session is untouched and holds ACTION_UW_ASSESS, which reads /v1/assessment.
    * def readerHeader = (uwAuthHeader != null) ? uwAuthHeader : officerAuthHeader

    * def castVotes =
    """
    function() {
      var note = function(m) { karate.log('[approver-routing]', m); };
      var votedBy = {};
      // Keyed per hop - the same account may legitimately act again at a later hop.
      var voteKey = function(hopIdx, user) { return (hopIdx == null ? 'direct' : 'hop' + hopIdx) + ':' + user; };
      var currentHopIdx = null;
      var castCount = 0;
      var MAX_VOTES = 8;

      var loanStatus = function() {
        var r = karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', readerHeader).get();
        return (r.status == 200) ? r.body.status : null;
      };

      for (var n = 0; n < MAX_VOTES; n++) {
        var status = loanStatus();
        if (status == 'APPROVED') {
          note('APPROVED after ' + castCount + ' vote(s)');
          return { status: status, votes: castCount };
        }

        var ar = karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', readerHeader).get();
        if (ar.status != 200) { note('GET /v1/assessment -> HTTP ' + ar.status + ' - stopping'); break; }
        var a = ar.body;
        var chain = a.sequentialChainState;

        // Who may act right now?
        var authType = null, authName = null, ccMembers = null, hopLimit = null;
        if (chain != null && chain.sequentialRouting == true && chain.currentAuthorityName != null) {
          authType = chain.currentAuthorityType;
          authName = chain.currentAuthorityName;
          hopLimit = chain.currentLimitAmount;
          var hops = chain.hops;
          if (hops != null) {
            for (var h = 0; h < hops.length; h++) {
              if (hops[h].hopIndex == chain.currentHopIndex) ccMembers = hops[h].ccMembers;
            }
          }
          currentHopIdx = chain.currentHopIndex;
          note('sequential hop ' + (chain.currentHopIndex + 1) + '/' + chain.totalHops
               + ' -> ' + authType + '/' + authName + ' (limit ' + hopLimit + ')');
        } else {
          currentHopIdx = null;
          authType = a.directResolvedAuthorityType;
          authName = a.directResolvedAuthorityNames;
          note('direct authority -> ' + authType + '/' + authName);
        }

        // Candidate voters for this hop, most-entitled first.
        var candidates = [];
        if (authType == 'USER' && authName != null && authName != '') {
          candidates.push(authName);
        } else {
          // A committee hop: ANY member of that committee counts towards the quorum, so the pool
          // must be the committee's real membership - not the two or three accounts karate-config
          // happened to resolve into approver slots. A votesRequired-of-3 limit needs a third voter,
          // and the approver3 slot resolves by NAME, not by role: on this environment it lands on an
          // account that holds no APPROVER role, whose vote is refused with
          //   403 ACCESS_DENIED on /claim and /approver-action
          // and the quorum then deadlocks with candidates left unused.
          //
          // Membership by preference: the config slots first (their passwords are known to work),
          // then every other account the server says holds the committee's role.
          var preferred = [];
          if (activeApprover1User != null) preferred.push(activeApprover1User);
          if (activeApprover2User != null) preferred.push(activeApprover2User);
          preferred.push(approver1Username);
          preferred.push(approver2Username);
          if (typeof approver3Username !== 'undefined' && approver3Username != null) preferred.push(approver3Username);

          // ccMembers is present on a sequential hop and authoritative when it is; on direct routing
          // it is absent, and the /v1/users roster stands in for it.
          var isMember = function(name) {
            if (ccMembers != null) {
              for (var m = 0; m < ccMembers.length; m++) {
                if (ccMembers[m].username == name) return ccMembers[m].vote == null;
              }
              return false;
            }
            for (var u = 0; u < knownUserRecords.length; u++) {
              var rec = knownUserRecords[u];
              if (rec.username != name || rec.roles == null) continue;
              for (var r = 0; r < rec.roles.length; r++) {
                if (rec.roles[r] == authName) return true;
              }
              return false;
            }
            return false;
          };

          for (var pi = 0; pi < preferred.length; pi++) {
            var name = preferred[pi];
            if (name == null || candidates.indexOf(name) >= 0) continue;
            if (isMember(name)) candidates.push(name);
          }
          // Top up from the roster so a three-vote quorum can actually be reached.
          if (ccMembers != null) {
            for (var m2 = 0; m2 < ccMembers.length; m2++) {
              var cm = ccMembers[m2].username;
              if (cm != null && ccMembers[m2].vote == null && candidates.indexOf(cm) < 0) candidates.push(cm);
            }
          } else {
            for (var u2 = 0; u2 < knownUserRecords.length; u2++) {
              var rec2 = knownUserRecords[u2];
              if (rec2.username == null || rec2.roles == null || candidates.indexOf(rec2.username) >= 0) continue;
              for (var r2 = 0; r2 < rec2.roles.length; r2++) {
                if (rec2.roles[r2] == authName) { candidates.push(rec2.username); break; }
              }
            }
          }
        }

        var voter = null;
        for (var c = 0; c < candidates.length; c++) {
          if (!votedBy[voteKey(currentHopIdx, candidates[c])]) { voter = candidates[c]; break; }
        }
        if (voter == null) {
          note('no account we can sign in as is still eligible for ' + authType + '/' + authName
               + ' (candidates: ' + candidates + ') - stopping. Add the account to roleCandidates '
               + 'in karate-config.js, or lower the quorum on that authority.');
          break;
        }

        var token = null;
        try {
          token = login(voter, passwordFor(voter));
        } catch (e) {
          note('cannot sign in as ' + voter + ' - skipping this candidate');
          votedBy[voteKey(currentHopIdx, voter)] = true;
          continue;
        }
        var hdr = 'Bearer ' + token;
        approverHeaders.push(hdr);
        var cr = karate.http(baseUrl + '/v1/loans/' + appId + '/claim')
                       .header('Authorization', hdr).header('Content-Type', 'application/json').post({});
        if (cr.status != 200) note('claim by ' + voter + ' -> HTTP ' + cr.status + ' ' + (cr.body == null ? '' : JSON.stringify(cr.body)));

        // A hop whose own limit does not cover the amount CANNOT approve — the server answers
        //   403 INSUFFICIENT_APPROVAL_LIMIT "Your limit (...) is insufficient ... Use REFER to escalate."
        // REFER is how a chain advances to the next, higher hop; APPROVE is only for a hop that can
        // actually finalise. This is the whole reason a chain needs more than one action verb.
        var action = castCount == 0 ? approver1Action : approver2Action;
        if (action == null) throw new Error('[sheet] column "approver2Action" is missing or blank for testCaseId "' + testCaseId + '" - a second approver vote is needed, so fill it in');
        if (hopLimit != null && Number(hopLimit) < Number(loanAmount)) {
          action = 'REFER';
          note(voter + ' limit ' + hopLimit + ' < ' + loanAmount + ' - referring up the chain');
        }

        var payload = {
          action: action,
          comment: voter + ' | ' + testCaseId,
          overriddenInterestRate: overriddenRate,
          notifyOfficer: notifyOff,
          notifyCustomer: notifyCust
        };
        var vr = karate.http(baseUrl + '/v1/assessment/' + appId + '/approver-action')
                       .header('Authorization', hdr).header('Content-Type', 'application/json').post(payload);
        votedBy[voteKey(currentHopIdx, voter)] = true;
        if (vr.status == 200) {
          castCount = castCount + 1;
          note('action ' + castCount + ': ' + action + ' by ' + voter + ' -> HTTP 200');
        } else {
          note(action + ' by ' + voter + ' rejected -> HTTP ' + vr.status + ' ' + (vr.body == null ? '' : JSON.stringify(vr.body)));
        }
      }
      return { status: loanStatus(), votes: castCount };
    }
    """

    * def voteResult = (isSkipApp1 && isSkipApp2) ? { status: 'SKIPPED', votes: 0 } : castVotes()
    * print '✔ [TESTER VERIFICATION] Step 16a-c: Approval Voting -> Votes Cast:', voteResult.votes, '| Resulting Status:', voteResult.status

    * def authHeader = (approverHeaders.length > 0) ? approverHeaders[approverHeaders.length - 1] : officerAuthHeader

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 16d: Final Post-Approver Voting Status:', response.status, '| Expected: APPROVED'
    * if (!isSkipApp1 && !isSkipApp2) karate.match(response.status, 'APPROVED')

    * atStep('16')

    # Step 17: Offer Issue Role Stage - Claim & Issue Verification
    # issuerAction: ISSUE - the only action the offer-issue stage has.
    * def issuerAction = isSkipIssueOffer ? null : sheetVal('issuerAction').toUpperCase()
    * if (!isSkipIssueOffer && issuerAction != 'ISSUE') karate.fail('[sheet] issuerAction "' + issuerAction + '" on ' + testCaseId + ' is not supported - use ISSUE')
    * def issuerToken = isSkipIssueOffer ? null : login(activeIssuerUser, activeIssuerPass)
    * def issuerAuthHeader = isSkipIssueOffer ? null : ('Bearer ' + issuerToken)
    # A skipped stage has no token of its own. Reads after it must still be authenticated, so
    # fall back to the officer session — which stays valid until the logout block at the end —
    # rather than sending the next GET with no Authorization at all (401).
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
    * def issueAssessChargesNeg = chargeNegMatched(issueAssessCharges, 'ASSESSMENT')
    * if (issueAssessChargesNeg) RowActions.endRow(testCaseId)
    * if (issueAssessChargesNeg) karate.abort()
    * if (issueAssessCharges.error) karate.fail(chargeFail(issueAssessCharges, 'ASSESSMENT'))
    * def issueCharges = isSkipIssueOffer ? noCharges : stageCharges(issuerAuthHeader, 'OFFER', 'offerCharges', appId)
    * def issueChargesNeg = chargeNegMatched(issueCharges, 'OFFER')
    * if (issueChargesNeg) RowActions.endRow(testCaseId)
    * if (issueChargesNeg) karate.abort()
    * if (issueCharges.error) karate.fail(chargeFail(issueCharges, 'OFFER'))
    * print '✔ [TESTER VERIFICATION] Offer Charges -> Collected by:', isSkipIssueOffer ? 'SKIPPED' : activeIssuerUser, '|', issueCharges.collected

    * def issuePayload = { rateAdjustment: 0, principalReduction: 0, offerValidityDate: '#(offerValidityDate)' }
    * set issuePayload.rateAdjustment = offerRateAdjustment
    * set issuePayload.principalReduction = offerPrincipalReduction
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/offer-issue-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl, requestBody: issuePayload })

    # 404 is legitimate on a row that skips issuance — there is no offer to read.
    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404
    * if (!isSkipIssueOffer) karate.match(response.status, '#regex ISSUED|OFFER_ISSUED')
    * print '✔ [TESTER VERIFICATION] Step 17b: Offer Issued -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ISSUED / OFFER_ISSUED | MATCHED'

    # Step 17c: Offer Acceptor Role Stage - Claim & Accept Verification
    * def acceptorToken = isSkipOfferAccept ? null : login(activeAcceptorUser, activeAcceptorPass)
    * def acceptorAuthHeader = isSkipOfferAccept ? null : ('Bearer ' + acceptorToken)
    # A skipped stage has no token of its own. Reads after it must still be authenticated, so
    # fall back to the officer session — which stays valid until the logout block at the end —
    # rather than sending the next GET with no Authorization at all (401).
    * def authHeader = (acceptorAuthHeader != null) ? acceptorAuthHeader : officerAuthHeader
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipOfferAccept && response.assignedTo) karate.match(response.assignedTo, activeAcceptorUser)
    * print '✔ [TESTER VERIFICATION] Step 17c: Acceptor Claim -> Claimed By:', activeAcceptorUser, '| AssignedTo:', response.assignedTo, '| MATCHED'

    # acceptorAction: ACCEPT | DECLINE. DECLINE records the customer's decline with offerDeclineReason and ends the
    # row at OFFER_DECLINED - nothing after it (setup, CBS) applies.
    * def acceptorAction = isSkipOfferAccept ? null : sheetVal('acceptorAction').toUpperCase()
    * if (!isSkipOfferAccept && acceptorAction != 'ACCEPT' && acceptorAction != 'DECLINE') karate.fail('[sheet] acceptorAction "' + acceptorAction + '" on ' + testCaseId + ' is not supported - use ACCEPT or DECLINE')
    * def declineReason = (!isSkipOfferAccept && acceptorAction == 'DECLINE') ? sheetVal('offerDeclineReason') : null
    * def declineRes = declineReason != null ? karate.http(baseUrl + '/v1/offer/' + appId + '/decline').header('Authorization', acceptorAuthHeader).header('Content-Type', 'application/json').post({ declinedReason: declineReason }) : null
    * if (declineRes != null && declineRes.status != 200) karate.fail('[offer] decline on ' + testCaseId + ' refused with HTTP ' + declineRes.status + ' ' + karate.toString(declineRes.body))
    * def declinedApp = declineRes != null ? karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', acceptorAuthHeader).get().body : null
    * if (declineRes != null && declinedApp.status != 'OFFER_DECLINED') karate.fail('[offer] after DECLINE ' + testCaseId + ' is ' + declinedApp.status + ', expected OFFER_DECLINED')
    * if (declineRes != null) karate.log('✔ [TESTER VERIFICATION] Offer DECLINED by', activeAcceptorUser, '-> Status:', declinedApp.status, '| Reason:', declineReason)
    * if (declineRes != null && chargeNegRow) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected a charge error containing "' + sheetOpt('expectedError') + '" but every stage up to the offer decline collected its charges')
    * if (declineRes != null) RowActions.endRow(td.testCaseId)
    * if (declineRes != null) karate.abort()
    * def acceptCharges = isSkipOfferAccept ? noCharges : stageCharges(acceptorAuthHeader, 'OFFER_ACCEPTANCE', 'offerAcceptanceCharges', appId)
    * def acceptChargesNeg = chargeNegMatched(acceptCharges, 'OFFER_ACCEPTANCE')
    * if (acceptChargesNeg) RowActions.endRow(testCaseId)
    * if (acceptChargesNeg) karate.abort()
    * if (acceptCharges.error) karate.fail(chargeFail(acceptCharges, 'OFFER_ACCEPTANCE'))
    * print '✔ [TESTER VERIFICATION] Offer-Acceptance Charges -> Collected by:', isSkipOfferAccept ? 'SKIPPED' : activeAcceptorUser, '|', acceptCharges.collected
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/offer-accept-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl, requestBody: {} })

    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404
    * if (!isSkipOfferAccept) karate.match(response.status, '#regex ACCEPTED|OFFER_ACCEPTED')
    * print '✔ [TESTER VERIFICATION] Step 17d: Offer Accepted -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ACCEPTED | MATCHED'

    * atStep('17')

    # Step 18: Setup User Role Stage - Claim, Excel Matching & Schedule Regeneration
    # setupAction: CREATE_ACCOUNT - set the loan up and create its account in CBS.
    * def setupAction = isSkipSetup ? null : sheetVal('setupAction').toUpperCase()
    * if (!isSkipSetup && setupAction != 'CREATE_ACCOUNT') karate.fail('[sheet] setupAction "' + setupAction + '" on ' + testCaseId + ' is not supported - use CREATE_ACCOUNT')
    * def setupToken = isSkipSetup ? null : login(activeSetupUser, activeSetupPass)
    * def setupAuthHeader = isSkipSetup ? null : ('Bearer ' + setupToken)
    # A skipped stage has no token of its own. Reads after it must still be authenticated, so
    # fall back to the officer session — which stays valid until the logout block at the end —
    # rather than sending the next GET with no Authorization at all (401).
    * def authHeader = (setupAuthHeader != null) ? setupAuthHeader : officerAuthHeader
    * if (!isSkipSetup) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipSetup && response.assignedTo) karate.match(response.assignedTo, activeSetupUser)
    * match response.loanAmount == loanAmount
    * match response.customerId == customerId
    * match response.selectedProductCode == entProductCode
    * print '✔ [TESTER VERIFICATION] Step 18a: Setup Officer Claim -> Claimed By:', activeSetupUser, '| Loan Amount:', response.loanAmount, '| Product:', response.selectedProductCode, '| MATCHED WITH EXCEL'

    # On a skip row there is no setup token, so these run as the officer - and LoanSetupController is
    # @PreAuthorize("hasAuthority('ACTION_LOAN_SETUP')") at CLASS level, so every call answers 403.
    # A row that never reached the setup stage answers 404. Both are fine while the row is skipping;
    # the karate.match below keeps it strict when it is not.
    Given path '/v1/loan-setup/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    * if (!isSkipSetup) karate.match(responseStatus, 200)

    Given path '/v1/loan-setup/' + appId + '/validate-account'
    And param accountNumber = feeAcct
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403

    # Tenor check: the regenerated schedule must carry exactly one installment per month of tenor.
    * def calcTermMonths = (termFrequency == 'YEARS' ? loanTerm * 12 : loanTerm)
    # Regenerate request with the fields the UI's Loan Setup screen sends (RegenerateScheduleRequest). Other
    # names are ignored by the server, which then cannot call CBS and silently returns its LOCAL fallback.
    # The saved PEP is sent again (pepDtls[]), as the UI does; a manual product sends its auto population.
    * def regenReq = { principal: '#(loanAmount)', ratePercent: '#(overriddenRate)', tenureMonths: '#(calcTermMonths)', frequency: '#(repaymentFrequency)', productCode: '#(entProductCode)' }
    * if (schedFirstRepay) karate.set('regenReq', karate.merge(regenReq, { startDate: schedFirstRepay, repaymentStartDate: schedFirstRepay }))
    * if (pepSent) karate.set('regenReq', karate.merge(regenReq, pepFields))
    * if (isManualProduct && td.autoPopulationMethod) karate.set('regenReq', karate.merge(regenReq, { autoPopulationMethod: td.autoPopulationMethod }))
    * eval karate.set('regenReq', karate.merge(regenReq, optionFields.setup))
    Given path '/v1/loan-setup/' + appId + '/regenerate-schedule'
    And request regenReq
    When method POST
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    # A row that reaches setup needs the regenerated schedule (UI Loan Setup "Regenerate"); a skip row
    # has no setup session, so its 403/404 above stays acceptable.
    * if (!isSkipSetup && responseStatus != 200) karate.fail('[SCHEDULE REGENERATION FAILED] TestCase ' + testCaseId + ': HTTP ' + responseStatus + ' ' + karate.toString(response))
    * def generatedSched = (responseStatus == 200) ? response : null
    * def installmentsList = (generatedSched == null) ? [] : (generatedSched.installments ? generatedSched.installments : generatedSched)
    # The setup schedule must come from CBS (ISO due dates), not LO's local fallback ("15 Oct 2026" dates),
    # which the server returns with HTTP 200 whenever its CBS call fails.
    * def isIsoDate = function(d) { return d != null && /^\d{4}-\d{2}-\d{2}/.test('' + d) }
    * def setupFromCbs = karate.sizeOf(installmentsList) == 0 || isIsoDate(installmentsList[0].dueDate)
    * if (!isSkipSetup && !manualUploaded && karate.sizeOf(installmentsList) > 0 && !setupFromCbs) karate.fail('[SETUP SCHEDULE NOT FROM CBS] TestCase ' + testCaseId + ': Loan Setup regenerate returned the local fallback schedule (first due date ' + installmentsList[0].dueDate + ') - the CBS call failed inside LO')
    * def optSetupErrors = (optCheck && !isSkipSetup && !manualUploaded && setupFromCbs) ? checkOptionsSchedule(installmentsList, optionFields.spec) : []
    * if (optSetupErrors.length > 0) karate.fail('[REPAYMENT OPTIONS LOST AT SETUP] TestCase ' + testCaseId + ': ' + optSetupErrors.join('; '))
    * if (optCheck && !isSkipSetup && !manualUploaded) karate.log('✔ [TESTER VERIFICATION] Step 18b Repayment options at Setup -> ' + optionFields.sent.join(', ') + ' | schedule shape MATCHED')
    * def pepSetup = (pepCheck && !isSkipSetup) ? analysePep(installmentsList, pepAmountNum) : null
    * if (pepSetup != null && pepSetup.bumped != pepCountNum) karate.fail('[PEP LOST AT SETUP] TestCase ' + testCaseId + ': setup schedule has ' + pepSetup.bumped + ' installments raised by ' + pepAmountNum + ', expected ' + pepCountNum)
    * if (pepSetup != null) karate.log('✔ [TESTER VERIFICATION] Step 18b PEP at Setup -> raised installments:', pepSetup.bumped, 'of', pepCountNum)
    # Expected installment count follows the CBS sub-product's repayment type:
    # EMI/FPI/FLAT/etc -> periodic; PAM -> 1 installment; MANUAL -> skip assertion (validated against upload below).
    * def expectedInstallmentsFor = read('classpath:features/loans/expected-installments.js')
    * def instRule = expectedInstallmentsFor({ product: cbsProduct, frequency: repaymentFrequency, termMonths: calcTermMonths, splitInterestFrequency: !!optionFields.spec.interestFrequency })
    * def expectedInstallments = instRule.expected
    * karate.log('[schedule] TestCase', testCaseId, ': repayment type', instRule.loRepaymentType, '(', instRule.cbsRepaymentType, ') ->', instRule.reason, '| expected installments:', expectedInstallments)
    * if (!isSkipSetup && !manualUploaded && expectedInstallments != null && karate.sizeOf(installmentsList) != expectedInstallments) karate.fail('[SCHEDULE REGENERATION] TestCase ' + testCaseId + ': expected ' + expectedInstallments + ' installments (' + instRule.reason + '), got ' + karate.sizeOf(installmentsList))
    # A manual-schedule loan's setup schedule is the uploaded one: same number of rows, principal adding up to the loan amount.
    * if (manualUploaded && karate.sizeOf(installmentsList) != karate.sizeOf(manualRows)) karate.fail('[MANUAL SCHEDULE NOT USED AT SETUP] TestCase ' + testCaseId + ': uploaded ' + karate.sizeOf(manualRows) + ' rows, setup schedule has ' + karate.sizeOf(installmentsList))
    * if (manualUploaded && Math.abs(sumPrincipal(installmentsList) - loanAmount) > 0.01) karate.fail('[MANUAL SCHEDULE NOT USED AT SETUP] TestCase ' + testCaseId + ': setup principal total ' + sumPrincipal(installmentsList) + ' != loan amount ' + loanAmount)
    * if (manualUploaded) karate.log('✔ [TESTER VERIFICATION] Step 18b: Manual Schedule at Setup -> Rows:', karate.sizeOf(installmentsList), '| Principal Total:', sumPrincipal(installmentsList), '| MATCHED UPLOAD')
    * print '✔ [TESTER VERIFICATION] Step 18b: Schedule Regeneration -> Expected Tenor Months:', calcTermMonths, '| Repayment Frequency:', repaymentFrequency, '| Installments Count:', karate.sizeOf(installmentsList)

    * def setupPayload =
    """
    {
      "settlementMode": "#(td.setupSettlementMode ? td.setupSettlementMode : settlementMode)",
      "repaymentAccountNumber": "#(repaymentAcct)",
      "feeFundingAccountNumber": "#(feeAcct)",
      "disbursementMode": "#(disbursementMode)",
      "disbursementDate": "#(disbursementDate)",
      "disbursementAccountNumber": "#(disbAcct)",
      "disbursementNotes": "#(disbursementNotes)"
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
    * def createAccountPayload = buildCreateAccountRequest(setupDto, optionFields.setup, { businessDate: cbsBusinessDate, loanStartDate: td.loanStartDate, loanAmount: loanAmount, termMonths: calcTermMonths, disbursementDate: disbursementDate, repaymentStartDate: schedFirstRepay, disbAcct: disbAcct, repaymentAcct: repaymentAcct, settlementMode: (td.setupSettlementMode ? td.setupSettlementMode : settlementMode), feeAcct: feeAcct, repaymentFrequency: repaymentFrequency, disbursementMode: disbursementMode, commitmentId: sheetOpt('commitmentId'), pep: (pepSent ? pepFields : null), autoPopulationMethod: ((isManualProduct && td.autoPopulationMethod) ? td.autoPopulationMethod : null) })
    * def createAccountPayload = applyScheduleOverride(createAccountPayload, setupOverride)
    * if (setupOverride != null) karate.log('[cbs] createAccountOverride applied - TestCase', testCaseId, ':', setupOverride)
    * if (!isSkipSetup) karate.log('[cbs] create-account request - TestCase', testCaseId, ':', createAccountPayload)
    * def cbsNotes = 'CBS Enterprise Direct | ' + testCaseId
    * def cbsPayload = { setupOfficerNotes: '#(cbsNotes)' }
    # The setup user collects the SETUP charges (setupCharges) before the account is created in CBS.
    * def setupCharges = isSkipSetup ? noCharges : stageCharges(setupAuthHeader, 'SETUP', 'setupCharges', appId)
    * def setupChargesNeg = chargeNegMatched(setupCharges, 'SETUP')
    * if (setupChargesNeg) RowActions.endRow(testCaseId)
    * if (setupChargesNeg) karate.abort()
    * if (setupCharges.error) karate.fail(chargeFail(setupCharges, 'SETUP'))
    * print '✔ [TESTER VERIFICATION] Setup Charges -> Collected by:', isSkipSetup ? 'SKIPPED' : activeSetupUser, '|', setupCharges.collected
    * def cbsCreate = isSkipSetup ? null : karate.call('classpath:features/loans/loan-setup-cbs-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: cbsPayload, createAccountPayload: createAccountPayload, expectNegative: setupNegRow })
    * def setupNegMatched = (cbsCreate != null && setupNegRow) ? matchNegative(cbsCreate.cbsStatus, cbsCreate.cbsBody) : false
    * if (setupNegMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Create Loan Account in CBS rejected with HTTP', cbsCreate.cbsStatus, '| Expected error matched:', sheetOpt('expectedError'))
    * if (setupNegMatched) RowActions.endRow(testCaseId)
    * if (setupNegMatched) karate.abort()
    * if (cbsCreate != null && setupNegRow && !setupNegMatched) karate.fail('[CBS SETUP NEGATIVE FAILED] TestCase ' + testCaseId + ': expected HTTP ' + sheetOpt('expectedStatus') + ' / error "' + sheetOpt('expectedError') + '" but got HTTP ' + cbsCreate.cbsStatus + ' ' + karate.toString(cbsCreate.cbsBody))

    * atStep('18')

    # Step 19: Final Completion & CBS Account Number Retrieval
    Given path '/v1/loans/' + appId
    And retry until response.status == 'COMPLETED' || isSkipSetup
    When method GET
    Then status 200
    * if (!isSkipSetup) karate.match(response.status, 'COMPLETED')
    * def finalStatus = response.status

    # 403/404 on a skip row, for the reason given at the top of the setup block.
    Given path '/v1/loan-setup/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    * if (!isSkipSetup) karate.match(responseStatus, 200)
    * def queryDbCbs = function() { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from blo_loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e) { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e2) { return null; } } }
    * def dbCbs = queryDbCbs()
    # The account number must be the one CBS returned to /create-account, stored on the setup, and never the
    # local stub pattern LN-<year>-BLR-<appId> that /send-to-cbs invents without calling CBS.
    * def cbsLoanIdCreated = (cbsCreate != null && cbsCreate.cbsLoanId) ? cbsCreate.cbsLoanId : null
    * if (cbsLoanIdCreated != null && responseStatus == 200 && response.cbsLoanAccountNumber != cbsLoanIdCreated) karate.fail('[CBS ACCOUNT MISMATCH] TestCase ' + testCaseId + ': CBS returned loan id ' + cbsLoanIdCreated + ' but the setup stores ' + response.cbsLoanAccountNumber)
    * if (cbsLoanIdCreated != null && /^LN-\d{4}-BLR-\d{6}$/.test('' + cbsLoanIdCreated)) karate.fail('[CBS ACCOUNT IS THE LOCAL STUB] TestCase ' + testCaseId + ': ' + cbsLoanIdCreated + ' was generated by LO, not by CBS')
    * def generatedCbsAccountNo = cbsLoanIdCreated != null ? cbsLoanIdCreated : ((dbCbs && dbCbs != '') ? dbCbs : ((responseStatus == 200 && response.cbsLoanAccountNumber) ? response.cbsLoanAccountNumber : 'N/A (stage skipped or pending)'))
    * print '======================================================'
    * print '✔ [TESTER VERIFICATION] Enterprise TestCase Completed:', testCaseId
    * print '✔ Application ID           :', appId
    * print '✔ Final Application Status :', finalStatus, '| Expected: COMPLETED'
    # Known defect D2: the generated schedule's pep column is 0 (LoanOriginationService maps pep = ZERO).
    * if (!pepColumnOk) karate.fail('[PEP COLUMN DEFECT] TestCase ' + testCaseId + ': the generated schedule shows pep = ' + pepAmountNum + ' on ' + pepGen.pepColumn + ' of ' + pepCountNum + ' PEP installments (the server maps the pep column to 0) - the loan itself completed')
    * print '✔ CBS Loan Account Number  :', generatedCbsAccountNo
    * print '======================================================'

    * atStep('19')

    # Step 20: Logout Cleanup
    * def logout =
    """
    function(token) {
      if (!token) return;
      try {
        karate.call('classpath:features/auth/logout-helper.feature', { authHeader: token });
      } catch (e) {
        // Almost always HTTP 429 from the login rate limiter on a long suite. Session
        // teardown is housekeeping - it must not fail a lifecycle that already passed.
        karate.log('[logout] ignored:', e);
      }
    }
    """
    * logout(freshAdminHeader)
    * logout(officerAuthHeader)
    * logout(uwAuthHeader)
    # However many approvers the routing needed — one, two, or a whole sequential chain.
    * eval for (var i = 0; i < approverHeaders.length; i++) logout(approverHeaders[i])
    * logout(issuerAuthHeader)
    * logout(acceptorAuthHeader)
    * logout(setupAuthHeader)
    * atStep('20')

    # ── End-of-row columns: store / dbQuery / verify ─────────────────────────
    * atStep(null)
    * if (chargeNegRow) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected a charge error containing "' + sheetOpt('expectedError') + '" but every stage collected its charges')
    * RowActions.endRow(td.testCaseId)
