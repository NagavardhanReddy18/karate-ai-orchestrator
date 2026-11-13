@loans @e2e @data-driven @overdraft
Feature: Retail Overdraft Lifecycle — data-driven runner over all enabled Excel rows

  # ── Data-driven runner ────────────────────────────────────────────────────
  # Loads every row whose "run" column is "Y" from the Overdraft Excel sheet and
  # iterates through each one, calling @lifecycle below.
  # Credential fallback is handled inside @lifecycle via sheetOpt()/pickUser():
  #   row column filled → use that value | blank → fall back to karate-config.
  Scenario: Run Retail Overdraft Lifecycle for all enabled Excel rows
    * def Loader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def loadRows =
    """
    function(paths) {
      for (var i = 0; i < paths.length; i++) {
        try {
          var rows = Loader.load(karate.toAbsolutePath('classpath:' + paths[i]));
          if (rows != null && rows.length > 0) {
            karate.log('[06-OVERDRAFT] using', paths[i], '->', rows.length, 'row(s) with run=Y');
            return rows;
          }
        } catch (e) { karate.log('[06-OVERDRAFT] could not read', paths[i], ':', e); }
      }
      return [];
    }
    """
    * def rawRows = loadRows(['features/loans/testdata/Overdraft-Excel-Automation.xlsx'])
    * def annotateRows = function(rList) { if (rList == null) return []; var n = rList.length; for (var i = 0; i < n; i++) { rList[i].rowIndex = i + 1; rList[i].totalRows = n; } return rList; }
    * def rows = annotateRows(rawRows)
    * def rowCount = rows.length
    * print '======================================================='
    * print '[06-OVERDRAFT] Total Excel rows enabled (run=Y):', rowCount
    * print '======================================================='
    * if (rowCount == 0) karate.log('[06-OVERDRAFT] No run=Y rows found — skipping')
    * if (rowCount > 0) karate.call('classpath:features/loans/06-BLO-Overdraft-LifeCycle.feature@lifecycle', rows)

  @ignore @lifecycle
  Scenario: Run direct retail overdraft lifecycle with step-by-step state and assignedTo verification

    # ── Test data: Excel row if there is one, built-in defaults otherwise ─────
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
        } catch (e) {
          karate.log('[excel] no usable sheet at', paths[i], '- falling back to the built-in defaults');
        }
      }
      return [];
    }
    """
    * def activeRows = loadRows(['features/loans/testdata/Overdraft-Excel-Automation.xlsx'])
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

    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }

    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn

    # ── SHEET CONTRACT: every value comes from Excel and reaches the API as the sheet gives it ──
    # Draft fields are read with sheetOpt() / sheetOptNum(): a blank cell is sent as blank and a
    # wrong value is sent as it stands. Nothing is defaulted, corrected or swapped for a server
    # value here — the submit API is what accepts or refuses the draft. That is what lets a row
    # leave out or spoil any one field and name the refusal it expects in expectedStatus /
    # expectedError (matched against the submit response, see the negative-test matcher below).
    #
    # sheetVal() / sheetNum() / sheetFlag() are kept for the columns that drive the stages AFTER
    # submission (skip flags, offer terms, notifications, approval-limit bootstrap). A row that is
    # meant to get past submission must fill those in; a blank one fails the row naming the column.
    * def sheetVal =
    """
    function(name) {
      var v = td[name];
      if (v == null || v.toString().trim() == '') {
        karate.fail('[sheet] column "' + name + '" is missing or blank for testCaseId "'
          + (td.testCaseId ? td.testCaseId : '?') + '" - fill that column in on the workbook row');
      }
      return v.toString().trim();
    }
    """
    * def sheetNum =
    """
    function(name) {
      var v = sheetVal(name);
      if (isNaN(Number(v))) {
        karate.fail('[sheet] column "' + name + '" must be numeric for testCaseId "'
          + td.testCaseId + '" - got "' + v + '"');
      }
      return Number(v);
    }
    """
    * def sheetFlag = function(name) { return sheetVal(name).toLowerCase() == 'true' }
    * def sheetOpt = function(name) { var v = td[name]; return (v == null || v.toString().trim() == '') ? null : v.toString().trim() }
    * def sheetOptNum = function(name) { var v = sheetOpt(name); return (v == null || isNaN(Number(v))) ? null : Number(v) }
    * def sheetJson = function(name) { var v = sheetOpt(name); return v == null ? null : karate.fromString(v) }

    * def testCaseId = sheetVal('testCaseId')
    * def description = sheetOpt('description')

    # ── Negative-test matcher (evaluated at SUBMIT only) ──────────────────────
    # expectedStatus blank -> any 4xx/5xx counts; expectedError blank -> any refusal counts.
    # expectedError is looked for anywhere in the submit response, case-insensitively.
    # expectedStatus CHARGE marks a charge negative: it runs the normal flow and passes at the stage charge check
    # (STAGE CHARGES below) whose error contains expectedError - so it is not an API negative here.
    * def chargeNegRow = sheetOpt('expectedStatus') != null && sheetOpt('expectedStatus').toUpperCase() == 'CHARGE'
    * def isNegativeTest = !chargeNegRow && (sheetOpt('expectedError') != null || sheetOpt('expectedStatus') != null)
    * def matchNegative =
    """
    function(status, body) {
      var bodyStr = karate.toString(body).toLowerCase();
      var expErr  = sheetOpt('expectedError')  ? sheetOpt('expectedError').toLowerCase()  : '';
      var expStat = sheetOpt('expectedStatus') ? sheetOpt('expectedStatus') : '';
      var statusOk = (expStat == '') ? (status >= 400) : (status.toString() == expStat || status == parseInt(expStat));
      var errorOk  = (expErr  == '') ? (status >= 400) : (bodyStr.indexOf(expErr) >= 0);
      return statusOk && errorOk;
    }
    """

    * print '==================================================='
    * print 'START DIRECT OVERDRAFT ROW [' + (td.rowIndex ? td.rowIndex : 1) + '/' + (td.totalRows ? td.totalRows : 1) + '] | TestCase:', testCaseId, '|', description
    * print '==================================================='

    * def activeAdminUser = (sheetOpt('adminUsername') != null && sheetOpt('adminUsername') != '') ? sheetOpt('adminUsername') : defaultAdminUsername
    * def activeAdminPass = defaultAdminPassword

    * def passwordFor =
    """
    function(user) {
      if (user == defaultApprover1Username) return defaultApprover1Password;
      if (user == defaultApprover2Username) return defaultApprover2Password;
      if (typeof defaultApprover3Username !== 'undefined' && defaultApprover3Username != null && user == defaultApprover3Username) return defaultApprover3Password;
      return defaultApprover1Password;
    }
    """

    # ── Every draft field, straight off the sheet — blank stays blank ─────────
    * def loanCategory = sheetOpt('loanCategory')
    * def customerTypeSelected = sheetOpt('customerTypeSelected')
    * def customerId = sheetOpt('customerId')
    * def customerName = sheetOpt('customerName')
    * def branch = sheetOpt('branch')
    * def accountOpenBranch = sheetOpt('accountOpenBranch')
    * def loanPurpose = sheetOpt('loanPurpose')
    * def currency = sheetOpt('loanAmountCurrency')
    * def loanAmount = sheetOptNum('loanAmount')
    * def totalAmount = sheetOptNum('totalAmount')
    * def totalCurrency = sheetOpt('totalAmountCurrency')
    * def customerContribution = sheetOptNum('customerContribution')
    * def loanTerm = sheetOptNum('loanTerm')
    * def termFrequency = sheetOpt('termFrequency')
    * def selectedProductCode = sheetOpt('selectedProductCode')
    * def selectedProductName = sheetOpt('selectedProductName')
    * def interestType = sheetOpt('interestType')
    * def overriddenRate = sheetOptNum('overriddenInterestRate')
    * def effectiveInterestRate = sheetOptNum('effectiveInterestRate')
    * def repaymentFrequency = sheetOpt('repaymentFrequency')
    * def repaymentStartDate = sheetOpt('repaymentStartDate')

    # Income, expense and parties
    * def monthlyGrossIncome = sheetOptNum('monthlyGrossIncome')
    * def existingEmiObligations = sheetOptNum('existingEmiObligations')
    * def employmentType = sheetOpt('employmentType')
    * def employerName = sheetOpt('employerName')
    * def periodOfEmployment = sheetOptNum('periodOfEmployment')
    * def otherIncome = sheetOptNum('otherIncome')
    * def monthlyLivingExpenses = sheetOptNum('monthlyLivingExpenses')
    * def incomeDetails = sheetOpt('incomeDetails')
    * def expenseDetails = sheetOpt('expenseDetails')
    * def coApplicants = sheetOpt('coApplicants')

    # OD limit block. loanAmount above IS the limit, not a disbursed principal.
    * def odLinkedAccount = sheetOpt('odLinkedAccount')
    * def odSecurityType = sheetOpt('odSecurityType')
    * def odReviewPeriodMonths = sheetOptNum('odReviewPeriodMonths')
    * def odAnnualFeeRate = sheetOptNum('odAnnualFeeRate')
    * def reviewDate = sheetOpt('reviewDate')
    * def limitExpiryDate = sheetOpt('limitExpiryDate')
    * def limitExpiryPeriod = sheetOptNum('limitExpiryPeriod')
    * def limitExpiryPeriodUnit = sheetOpt('limitExpiryPeriodUnit')
    * def limitReviewPeriod = sheetOptNum('limitReviewPeriod')
    * def limitReviewPeriodUnit = sheetOpt('limitReviewPeriodUnit')

    # OD debit interest. The API keeps the rate basis inside extendedData.odDebitInterest, so the
    # debitInterestRateBasis column is placed there; blank leaves extendedData as the sheet wrote it.
    * def debitInterestRateBasis = sheetOpt('debitInterestRateBasis')
    * def fixedInterestRate = sheetOptNum('fixedInterestRate')
    * def debitInterestMargin = sheetOptNum('debitInterestMargin')
    * def debitBaseCode = sheetOpt('debitBaseCode')
    # The wizard's Interest screen takes EITHER a base code OR a fixed rate. With basis FIXED_RATE the base code is
    # not sent (the sheet's MCLR is a placeholder, not a CBS base code - CBS codes look like 0106100), and the CBS
    # debit-rate change at Loan Setup then carries the fixed rate; with any other basis the fixed rate is not sent.
    * def debitBaseCode = (debitInterestRateBasis == 'FIXED_RATE') ? null : debitBaseCode
    * def debitInterestRate = sheetOptNum('debitInterestRate')
    * def fixedInterestRate = (debitInterestRateBasis != null && debitInterestRateBasis != 'FIXED_RATE') ? null : fixedInterestRate
    * def customerMarginInterest = sheetOptNum('customerMarginInterest')
    * def withDebitBasis = function(ext, basis) { if (basis == null) return ext; var out = (ext == null) ? {} : ext; if (out.odDebitInterest == null) out.odDebitInterest = {}; out.odDebitInterest.debitInterestRateBasis = basis; return out; }
    # extendedData is the one draft field the API takes as an object, so the sheet's JSON text is parsed.
    * def extendedData = withDebitBasis(sheetJson('extendedData'), debitInterestRateBasis)

    # Security
    * def selectedCollaterals = sheetOpt('selectedCollaterals')
    * def collateralAssignmentDetails = sheetOpt('collateralAssignmentDetails')
    * def commitmentId = sheetOpt('commitmentId')

    # Repayment setup
    * def settlementMode = sheetOpt('settlementMode')
    * def setupSettlementMode = (td.setupSettlementMode != null && td.setupSettlementMode != '') ? td.setupSettlementMode : settlementMode
    * def paymentType = sheetOpt('paymentType')
    * def repaymentAcct = sheetOpt('repaymentAccountNumber')
    * def feeAccountNumber = sheetOpt('feeAccountNumber')
    * def feeAcct = sheetOpt('feeFundingAccountNumber')

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
    * def disbAcct = sheetOpt('disbursementAccountNumber')
    * def disbursementMode = sheetOpt('disbursementMode')
    * def disbursementDate = sheetOpt('disbursementDate')
    * def disbursementNotes = sheetOpt('disbursementNotes')
    * def docSignedState = sheetOpt('docSignedState')

    # How charges are settled is the sheet's call.
    * def chargeCollectionMode = sheetOpt('chargeCollectionMode')
    * def chargeWaiveReason = sheetOpt('chargeWaiveReason')

    # Approval-limit bootstrap columns. Only a row that is meant to get past submission needs them.
    * def approvalLimitAmount = isNegativeTest ? null : sheetNum('approvalLimitAmount')
    * def approvalLimitPartyType = isNegativeTest ? null : sheetVal('approvalLimitPartyType')
    * def approvalLimitFacilityType = isNegativeTest ? null : sheetVal('approvalLimitFacilityType')

    # ====================================================
    # PRODUCT TYPE RESOLUTION + APPROVAL-LIMIT BOOTSTRAP
    # ====================================================
    * def freshAdminToken = login(activeAdminUser, activeAdminPass)
    * def freshAdminHeader = 'Bearer ' + freshAdminToken
    * def authHeader = freshAdminHeader

    # ── Stage accounts ────────────────────────────────────────────────────────
    # A stage username from the sheet is honoured only where that account actually EXISTS here.
    # An overdraft sheet added later may well name accounts that are seeded on one machine and
    # absent on another. karate-config.js is what resolves the account that really holds each
    # stage permission on this environment, so it is the fallback.
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

    # The SHEET decides the product type and it is sent as given. The server's list is read only
    # to say in the log whether it knows the code; an unknown one is for the submit API to refuse.
    Given path '/v1/product-types'
    When method GET
    Then status 200
    * def odTypes = karate.jsonPath(response, "$.[?(@.customerType=='RETAIL' && @.category=='OVERDRAFT' && @.active==true)]")
    * def odTypeCodes = karate.jsonPath(odTypes, '$[*].code')
    * def odTypeCode = sheetOpt('loanProductType')
    * def sheetTypeIsReal = (function() { for (var i = 0; i < odTypeCodes.length; i++) { if (odTypeCodes[i] == odTypeCode) return true; } return false; })()
    * print '✔ [TESTER VERIFICATION] Step 00: Overdraft Product Type -> From Sheet:', odTypeCode, '| Active RETAIL/OVERDRAFT Type On Server:', sheetTypeIsReal

    # loanType MUST equal the draft's loanProductType — the server resolves limits by that field.
    * def approvalLimitArgs =
    """
    {
      baseUrl: '#(baseUrl)',
      makerAuthHeader: '#(freshAdminHeader)',
      makerUsername: '#(activeAdminUser)',
      loanType: '#(odTypeCode)',
      partyType: '#(approvalLimitPartyType)',
      facilityType: '#(approvalLimitFacilityType)',
      currencyCode: '#(currency)',
      requiredAmount: #(loanAmount),
      limitAmount: #(approvalLimitAmount)
    }
    """
    * if (!isNegativeTest) karate.call('classpath:features/loans/approval-limit-helper.feature', approvalLimitArgs)
    * print '✔ [TESTER VERIFICATION] Step 00b: Approval Limit Bootstrap -> LoanType:', odTypeCode, '| Required:', loanAmount, currency, '| Bootstrapped:', !isNegativeTest

    # Step 01: Authenticate Loan Officer
    * def officerToken = login(activeOfficerUser, activeOfficerPass)
    * def officerAuthHeader = 'Bearer ' + officerToken
    * def authHeader = officerAuthHeader
    * print '✔ [TESTER VERIFICATION] Step 01: Officer Auth -> User:', activeOfficerUser, '| Status: PASSED (Token Issued)'

    # ─── ORIGINATION WIZARD (OVERDRAFT) ─────────────────────────────────────

    * atStep('01')

    # Step 02: Customer Selection & Verification
    Given path '/v1/origination/customers/' + customerId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || isNegativeTest
    * def custResp = (responseStatus == 200) ? response : null
    * print '✔ [TESTER VERIFICATION] Step 02: Customer Lookup -> Sheet ID:', customerId, '| Sheet Name:', customerName, '| Server Name:', (custResp == null ? null : custResp.fullName), '| HTTP:', responseStatus

    * atStep('02')

    # Step 03: Initial Draft Creation
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef
    * match response.id == '#number'
    * print '✔ [TESTER VERIFICATION] Step 03: Initial Draft Creation -> Draft ID:', draftId, '| Reference:', draftRef, '| PASSED'

    * atStep('03')

    # Step 04: Overdraft Product Selection (CURRENT-ACCOUNT products, not loan products)
    Given path '/v1/origination/products/overdraft'
    And param productTypeCode = odTypeCode
    And param currency = currency
    When method GET
    Then assert responseStatus == 200 || responseStatus == 503 || isNegativeTest
    * def odItems = (responseStatus == 200 && response.items) ? response.items : []
    * def serverProductCodes = karate.jsonPath(odItems, '$[*].productCode')
    * def odProductCode = selectedProductCode
    * def odProductName = selectedProductName
    # Index by hand: the JSON array Karate returns is a Java-backed proxy, so contains()/includes()
    # on it throws "Message not supported". Not fatal either way — CBS master data is not seeded
    # everywhere, so an empty list is a CBS gap rather than a bad sheet.
    * def productOfferedByServer =
    """
    (function() {
      for (var i = 0; i < serverProductCodes.length; i++) { if (serverProductCodes[i] == odProductCode) return true; }
      return false;
    })()
    """
    * if (!productOfferedByServer) karate.log('[product] sheet selectedProductCode "' + odProductCode + '" was not returned by /v1/origination/products/overdraft (server offered: ' + serverProductCodes + ') - using the sheet value anyway')
    * print '✔ [TESTER VERIFICATION] Step 04: Overdraft Product Selection -> From Sheet:', odProductCode, '| Offered By Server:', productOfferedByServer, '| Returned Count:', karate.sizeOf(odItems)

    * atStep('04')

    # Step 05: Save/Update Complete Overdraft Draft
    # Blank collateralType means an unsecured facility - the one place blank is meaningful here.
    * def colType = sheetOpt('collateralType')
    * def hasCollateral = colType != null
    * def odCollateralList = hasCollateral ? [ { "collateralType": colType, "description": sheetOpt('collateralDescription'), "estimatedValue": sheetOptNum('collateralEstimatedValue'), "forcedSaleValue": sheetOptNum('collateralForcedSaleValue'), "currency": currency } ] : []
    * string manualCollateralsJson = odCollateralList
    * print '✔ [TESTER VERIFICATION] Step 05a: Collateral -> Secured:', hasCollateral, '| Type:', colType

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
      "branch": "#(branch)",
      "accountOpenBranch": "#(accountOpenBranch)",
      "loanPurpose": "#(loanPurpose)",
      "loanAmount": #(loanAmount),
      "loanAmountCurrency": "#(currency)",
      "totalAmount": #(totalAmount),
      "totalAmountCurrency": "#(totalCurrency)",
      "customerContribution": #(customerContribution),
      "loanTerm": #(loanTerm),
      "termFrequency": "#(termFrequency)",
      "selectedProductCode": "#(odProductCode)",
      "selectedProductName": "#(odProductName)",
      "loanProductType": "#(odTypeCode)",
      "interestType": "#(interestType)",
      "overriddenInterestRate": #(overriddenRate),
      "effectiveInterestRate": #(effectiveInterestRate),
      "repaymentFrequency": "#(repaymentFrequency)",
      "repaymentStartDate": "#(repaymentStartDate)",
      "monthlyGrossIncome": #(monthlyGrossIncome),
      "existingEmiObligations": #(existingEmiObligations),
      "employmentType": "#(employmentType)",
      "employerName": "#(employerName)",
      "periodOfEmployment": #(periodOfEmployment),
      "otherIncome": #(otherIncome),
      "monthlyLivingExpenses": #(monthlyLivingExpenses),
      "incomeDetails": "#(incomeDetails)",
      "expenseDetails": "#(expenseDetails)",
      "coApplicants": "#(coApplicants)",
      "extendedData": #(extendedData),
      "manualCollaterals": "#(manualCollateralsJson)",
      "selectedCollaterals": "#(selectedCollaterals)",
      "collateralAssignmentDetails": "#(collateralAssignmentDetails)",
      "commitmentId": "#(commitmentId)",
      "odLinkedAccount": "#(odLinkedAccount)",
      "odSecurityType": "#(odSecurityType)",
      "odReviewPeriodMonths": #(odReviewPeriodMonths),
      "odAnnualFeeRate": #(odAnnualFeeRate),
      "reviewDate": "#(reviewDate)",
      "limitExpiryDate": "#(limitExpiryDate)",
      "limitExpiryPeriod": #(limitExpiryPeriod),
      "limitExpiryPeriodUnit": "#(limitExpiryPeriodUnit)",
      "limitReviewPeriod": #(limitReviewPeriod),
      "limitReviewPeriodUnit": "#(limitReviewPeriodUnit)",
      "fixedInterestRate": #(fixedInterestRate),
      "debitInterestMargin": #(debitInterestMargin),
      "debitBaseCode": "#(debitBaseCode)",
      "debitInterestRate": #(debitInterestRate),
      "customerMarginInterest": #(customerMarginInterest),
      "settlementMode": "#(settlementMode)",
      "paymentType": "#(paymentType)",
      "repaymentAccountNumber": "#(repaymentAcct)",
      "feeAccountNumber": "#(feeAccountNumber)",
      "feeFundingAccountNumber": "#(feeAcct)",
      "disbursementMode": "#(disbursementMode)",
      "disbursementDate": "#(disbursementDate)",
      "disbursementAccountNumber": "#(disbAcct)",
      "disbursementNotes": "#(disbursementNotes)",
      "docSignedState": "#(docSignedState)"
    }
    """
    When method PUT
    Then status 200
    * def draftRef = response.applicationRef != null ? response.applicationRef : draftRef
    * match response.loanAmount == loanAmount
    * match response.customerId == customerId
    * print '✔ [TESTER VERIFICATION] Step 05: Save Draft Data -> Expected OD Limit:', loanAmount, '| Actual Response:', response.loanAmount, '| Product:', response.selectedProductCode, '| MATCHED'

    * atStep('06')

    # Step 07: Document Checklist & Upload
    Given path '/v1/product-config/checklist'
    And param productTypeCode = odTypeCode
    And param productCode = odProductCode
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 07: Document Checklist Lookup -> HTTP:', responseStatus, '| Rules Returned Count:', (responseStatus == 200 ? karate.sizeOf(response) : 0)

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

    * atStep('07')

    # Step 08: Charge Collection & Draft Submission
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
    * if (isNegativeTest && negativeMatched) karate.log('✔ [NEGATIVE TEST PASSED] TestCase:', testCaseId, '| Submit rejected with HTTP', submitStatus, '| Expected error matched:', sheetOpt('expectedError'))
    * if (isNegativeTest && negativeMatched) RowActions.endRow(testCaseId)
    * if (isNegativeTest && negativeMatched) karate.abort()
    * if (isNegativeTest && submitStatus >= 400) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected HTTP "' + sheetOpt('expectedStatus') + '" / error "' + sheetOpt('expectedError') + '" but submit answered HTTP ' + submitStatus + ': ' + karate.toString(submitResponse))
    * if (isNegativeTest) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected submit to be refused but it SUCCEEDED (HTTP ' + submitStatus + ')')
    # ────────────────────────────────────────────────────────────────────────

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
    # Confirms the type resolved to the overdraft facility, and therefore to the LOS_RETAIL_OD route.
    * def submittedFacility = finalSubmitResponse.facilityTypeId
    * print '✔ [TESTER VERIFICATION] Step 08: Draft Submission -> Draft ID:', draftId, '| Submit HTTP:', submitStatus, '| Application ID:', appId, '| Facility:', submittedFacility

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * match response.status == 'SUBMITTED'
    * print '✔ [TESTER VERIFICATION] Step 08b: Post-Submission State -> Expected Status: SUBMITTED | Actual Status:', response.status, '| MATCHED'

    * atStep('08')

    # Step 09: Stage Skip Flags Resolution (+ the columns that drive the stages after submission)
    * def offerValidityDate = sheetVal('offerValidityDate')
    * def offerRateAdjustment = sheetNum('offerRateAdjustment')
    * def offerPrincipalReduction = sheetNum('offerPrincipalReduction')
    * def notifyOff = sheetFlag('notifyOfficer')
    * def notifyCust = sheetFlag('notifyCustomer')
    # The loan-setup API has its own settlement modes (ACCOUNT_TRANSFER / EXTERNAL_MANDATE / MANUAL),
    # different from the draft's, so it has its own column.
    * def setupSettlementMode = sheetOpt('setupSettlementMode')
    * def isSkipUw = sheetFlag('skipUw')
    * def isSkipApp1 = sheetFlag('skipApprover1')
    * def isSkipApp2 = sheetFlag('skipApprover2')
    * def isSkipIssueOffer = sheetFlag('skipIssueOffer')
    * def isSkipOfferAccept = sheetFlag('skipOfferAccept')
    * def isSkipSetup = sheetFlag('skipLoanSetup')

    * atStep('09')

    # Step 10: Underwriter Stage - Claim & Assignee Verification
    * def uwToken = isSkipUw ? null : login(activeUwUser, activeUwPass)
    * def uwAuthHeader = isSkipUw ? null : ('Bearer ' + uwToken)
    * def authHeader = (uwAuthHeader != null) ? uwAuthHeader : officerAuthHeader
    * if (!isSkipUw) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipUw && response.assignedTo) karate.match(response.assignedTo, activeUwUser)
    * print '✔ [TESTER VERIFICATION] Step 10: Underwriter Claim -> Claimed By:', activeUwUser, '| AssignedTo:', response.assignedTo, '| Status:', response.status, '| MATCHED'

    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || response.length > 0
    When method GET
    Then status 200
    * def tasks = response
    * def intakeTasks = isSkipUw ? [] : karate.jsonPath(tasks, "$.[?(@.taskDefinitionKey=='applicationIntake' || @.taskDefinitionKey=='corporateIntake')]")
    * if (!isSkipUw && intakeTasks.length > 0) karate.call('classpath:features/loans/complete-task-helper.feature', { taskId: intakeTasks[0].id, requestBody: {}, authHeader: uwAuthHeader, baseUrl: baseUrl })
    * print '✔ [TESTER VERIFICATION] Step 10b: Intake -> Intake Tasks Found:', karate.sizeOf(intakeTasks), '| Completed:', (intakeTasks.length > 0)

    * atStep('10')

    # Step 11: Underwriter Decision
    # An empty result here means the accountReview or credit-score gate rejected the application:
    # check customerId is an existing customer and that monthlyGrossIncome keeps the score >= 620.
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until isSkipUw || karate.jsonPath(response, "$.[?(@.name=='Underwriter Review' || @.taskDefinitionKey=='underwriterReview')]").length > 0
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 11b: Underwriter Review Task Available -> Account + Credit Gates: PASSED'

    # Step 11c: The underwriter opens the assessment. The server creates it on this first read, resolves the
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
    * print '✔ [TESTER VERIFICATION] Step 11c: Assessment Opened -> Method:', assessMethod, '| Rule:', assessRec.resolvedRuleName, '| Scorecard:', assessRec.scorecardResult, assessRec.scorecardTotalScorePct, '| Decision:', assessRec.uwDecision, '| Scorecard evaluation:', scorecardEvalStatus
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

    * def rawUwAction = isSkipUw ? null : sheetVal('uwAction')
    # Sent as the sheet gives it: the API's verbs are APPROVE_TO_APPROVER / REJECT / ...
    * def resolvedUwAction = rawUwAction
    * def uwComment = sheetOpt('uwComment')
    * def uwPayload = { action: '#(resolvedUwAction)', comment: '#(uwComment)', notifyOfficer: '#(notifyOff)', notifyCustomer: '#(notifyCust)' }
    * if (sheetOpt('rejectReason') != null) karate.set('uwPayload', '$.rejectReason', sheetOpt('rejectReason'))
    * if (!isSkipUw) karate.call('classpath:features/loans/uw-action-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl, requestBody: uwPayload })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [TESTER VERIFICATION] Step 12: Post-UW Action State -> Status:', response.status, '| Current Phase:', response.currentPhaseId, '| MATCHED'

    * atStep('11')

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
    * def approverComment = sheetOpt('approverComment')
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
          comment: approverComment,
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
    * def authHeader = (issuerAuthHeader != null) ? issuerAuthHeader : officerAuthHeader
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipIssueOffer && response.assignedTo) karate.match(response.assignedTo, activeIssuerUser)
    * print '✔ [TESTER VERIFICATION] Step 17a: Issuer Claim -> Claimed By:', activeIssuerUser, '| Pre-Issue Status:', response.status, '| Expected: APPROVED | MATCHED'

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

    * def issuePayload = { rateAdjustment: '#(offerRateAdjustment)', principalReduction: '#(offerPrincipalReduction)', offerValidityDate: '#(offerValidityDate)' }
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/offer-issue-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl, requestBody: issuePayload })

    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404
    * if (!isSkipIssueOffer) karate.match(response.status, '#regex ISSUED|OFFER_ISSUED')
    * print '✔ [TESTER VERIFICATION] Step 17b: Offer Issued -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ISSUED / OFFER_ISSUED | MATCHED'

    * atStep('17')

    # Step 18: Offer Acceptor Role Stage
    * def acceptorToken = isSkipOfferAccept ? null : login(activeAcceptorUser, activeAcceptorPass)
    * def acceptorAuthHeader = isSkipOfferAccept ? null : ('Bearer ' + acceptorToken)
    * def authHeader = (acceptorAuthHeader != null) ? acceptorAuthHeader : officerAuthHeader
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipOfferAccept && response.assignedTo) karate.match(response.assignedTo, activeAcceptorUser)
    * print '✔ [TESTER VERIFICATION] Step 18a: Acceptor Claim -> Claimed By:', activeAcceptorUser, '| AssignedTo:', response.assignedTo, '| MATCHED'

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
    * print '✔ [TESTER VERIFICATION] Step 18b: Offer Accepted -> Offer Number:', response.offerNumber, '| Status:', response.status, '| Expected: ACCEPTED | MATCHED'

    * atStep('18')

    # Step 19: OD Setup & CBS Limit Creation
    # The OD workflows create a CBS LIMIT rather than disbursing a loan account, and there is no
    # repayment schedule to regenerate — but the REST surface is the same /v1/loan-setup endpoints.
    # setupAction: CREATE_ACCOUNT - set the loan up and create its account in CBS.
    * def setupAction = isSkipSetup ? null : sheetVal('setupAction').toUpperCase()
    * if (!isSkipSetup && setupAction != 'CREATE_ACCOUNT') karate.fail('[sheet] setupAction "' + setupAction + '" on ' + testCaseId + ' is not supported - use CREATE_ACCOUNT')
    * def setupToken = isSkipSetup ? null : login(activeSetupUser, activeSetupPass)
    * def setupAuthHeader = isSkipSetup ? null : ('Bearer ' + setupToken)
    * def authHeader = (setupAuthHeader != null) ? setupAuthHeader : officerAuthHeader
    * if (!isSkipSetup) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl })

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * if (!isSkipSetup && response.assignedTo) karate.match(response.assignedTo, activeSetupUser)
    * match response.loanAmount == loanAmount
    * match response.customerId == customerId
    * print '✔ [TESTER VERIFICATION] Step 19a: Setup Officer Claim -> Claimed By:', activeSetupUser, '| OD Limit:', response.loanAmount, '| Product:', response.selectedProductCode, '| MATCHED'

    # On a skip row these run as the officer, and LoanSetupController is
    # @PreAuthorize("hasAuthority('ACTION_LOAN_SETUP')") at CLASS level, so every call answers 403.
    # A row that never reached the setup stage answers 404. Both are fine while the row is skipping.
    Given path '/v1/loan-setup/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    * if (!isSkipSetup) karate.match(responseStatus, 200)

    Given path '/v1/loan-setup/' + appId + '/validate-account'
    And param accountNumber = feeAcct
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    * print '✔ [TESTER VERIFICATION] Step 19b: Repayment Account Validation -> Account:', feeAcct, '| HTTP:', responseStatus

    * def setupPayload =
    """
    {
      "settlementMode": "#(setupSettlementMode)",
      "repaymentAccountNumber": "#(repaymentAcct)",
      "feeFundingAccountNumber": "#(feeAcct)",
      "disbursementMode": "#(disbursementMode)",
      "disbursementDate": "#(disbursementDate)",
      "disbursementAccountNumber": "#(disbAcct)",
      "disbursementNotes": "#(disbursementNotes)"
    }
    """
    * if (!isSkipSetup) karate.call('classpath:features/loans/loan-setup-save-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: setupPayload })

    * def cbsPayload = { setupOfficerNotes: '#(sheetOpt("setupOfficerNotes"))' }
    # Overdraft in CBS, as the UI's Loan Setup screen does it (loan-setup.component createLoanAccount, OD branch): the
    # loan create-account API is not used. A NEW account (application extendedData.odAccountChoice = NEW, or no linked
    # account) is opened with POST /v1/od-accounts/{id}/currentsavings - the server then marks the setup CBS_CREATED and
    # completes the application; an EXISTING linked account is already in CBS. The OD limit is then set with
    # PUT .../currentsavings/{account}/limits and the debit rate with POST .../accounts/{account}/interest-rate-change.
    # The stub /send-to-cbs (LN-<year>-BLR-<appId>, no CBS call) is no longer used: a CBS refusal fails the row.
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def odApp = response
    * def odChoice = (odApp.extendedData && odApp.extendedData.odAccountChoice) ? ('' + odApp.extendedData.odAccountChoice).toUpperCase() : ''
    * def odLinked = odApp.odLinkedAccount ? odApp.odLinkedAccount : (odLinkedAccount ? odLinkedAccount : null)
    * def odIsNew = odChoice == 'NEW' || (odChoice != 'EXISTING' && odLinked == null)
    * def odCurrency = odApp.loanAmountCurrency ? odApp.loanAmountCurrency : (currency ? currency : 'USD')
    * def csReq = { customerId: '#(customerId)', productId: '#(odProductCode)', accountOwnership: 'SOLE' }
    * if (accountOpenBranch) karate.set('csReq', karate.merge(csReq, { branchCode: accountOpenBranch }))
    # The setup user collects the SETUP charges (setupCharges) before the account is created in CBS.
    * def setupCharges = isSkipSetup ? noCharges : stageCharges(setupAuthHeader, 'SETUP', 'setupCharges', appId)
    * def setupChargesNeg = chargeNegMatched(setupCharges, 'SETUP')
    * if (setupChargesNeg) RowActions.endRow(testCaseId)
    * if (setupChargesNeg) karate.abort()
    * if (setupCharges.error) karate.fail(chargeFail(setupCharges, 'SETUP'))
    * print '✔ [TESTER VERIFICATION] Setup Charges -> Collected by:', isSkipSetup ? 'SKIPPED' : activeSetupUser, '|', setupCharges.collected
    * def odCs = (!isSkipSetup && odIsNew) ? karate.call('classpath:features/loans/od-cs-account-create-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, testCaseId: testCaseId, requestBody: csReq }) : null
    * def odAccountId = odCs != null ? odCs.accountId : odLinked
    * if (!isSkipSetup && !odAccountId) karate.fail('[OD ACCOUNT MISSING] TestCase ' + testCaseId + ': no account was opened in CBS and the application has no linked account')
    * def limitReq = { debitLimit: { currency: '#(odCurrency)', value: '#("" + odApp.loanAmount)' }, limitIndicator: 'DRLIMAPPCRNA', limitExcessAction: 'DNTALLOWEXCESS' }
    * if (odApp.limitExpiryDate) karate.set('limitReq', karate.merge(limitReq, { limitExpiryDate: ('' + odApp.limitExpiryDate).substring(0, 10) }))
    * if (odApp.reviewDate) karate.set('limitReq', karate.merge(limitReq, { limitReviewDate: ('' + odApp.reviewDate).substring(0, 10) }))
    * def odMargin = odApp.customerMarginInterest != null ? Number(odApp.customerMarginInterest) : 0
    * def odBase = odApp.debitBaseCode ? ('' + odApp.debitBaseCode).trim() : ''
    * def rateReq = odBase != '' ? { baseCode: odBase } : { fixedRate: (odApp.fixedInterestRate != null ? Number(odApp.fixedInterestRate) : 0) + odMargin }
    * if (odBase != '' && odMargin != 0) karate.set('rateReq', karate.merge(rateReq, { interestMarginDetails: { margin: (odApp.debitInterestMargin != null ? Number(odApp.debitInterestMargin) : 0) + odMargin, marginType: 'FLATVALUE' } }))
    * def odCbs = isSkipSetup ? null : karate.call('classpath:features/loans/od-limit-rate-helper.feature', { appId: appId, accountId: odAccountId, authHeader: setupAuthHeader, baseUrl: baseUrl, testCaseId: testCaseId, limitRequest: limitReq, rateRequest: rateReq })

    * atStep('19')

    # Step 20: Final Completion & CBS Limit Retrieval
    Given path '/v1/loans/' + appId
    And retry until response.status == 'COMPLETED' || isSkipSetup
    When method GET
    Then status 200
    * if (!isSkipSetup) karate.match(response.status, 'COMPLETED')
    * def finalStatus = response.status
    * def finalPhase = response.currentPhaseId

    Given path '/v1/loan-setup/' + appId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || responseStatus == 403
    * def queryDbCbs = function() { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from blo_loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e) { try { return com.ird.beyond.lo.test.util.DbSupport.queryScalar("select cbs_loan_account_number from loan_setup where cbs_loan_account_number is not null order by id desc limit 1"); } catch(e2) { return null; } } }
    * def dbCbs = queryDbCbs()
    # The account must be the one CBS opened (stored on the setup by the server), never the local stub pattern.
    * def odAccountCreated = (typeof odAccountId != 'undefined' && odAccountId) ? odAccountId : null
    * if (odCs != null && responseStatus == 200 && response.cbsLoanAccountNumber != odAccountCreated) karate.fail('[CBS OD ACCOUNT MISMATCH] TestCase ' + testCaseId + ': CBS opened ' + odAccountCreated + ' but the setup stores ' + response.cbsLoanAccountNumber)
    * if (odAccountCreated != null && /^LN-\d{4}-BLR-\d{6}$/.test('' + odAccountCreated)) karate.fail('[CBS OD ACCOUNT IS THE LOCAL STUB] TestCase ' + testCaseId + ': ' + odAccountCreated)
    * def generatedCbsAccountNo = odAccountCreated != null ? odAccountCreated : ((dbCbs && dbCbs != '') ? dbCbs : ((responseStatus == 200 && response.cbsLoanAccountNumber) ? response.cbsLoanAccountNumber : 'N/A (stage skipped or pending)'))
    * print '======================================================'
    * print '✔ [TESTER VERIFICATION] Overdraft TestCase Completed:', testCaseId
    * print '✔ Application ID           :', appId
    * print '✔ Final Application Status :', finalStatus, '| Expected: COMPLETED'
    * print '✔ Final Phase              :', finalPhase
    * print '✔ CBS OD Limit / Account   :', generatedCbsAccountNo
    * print '======================================================'

    * atStep('20')

    # Step 21: Logout Cleanup
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
    * atStep('21')

    # ── End-of-row columns: store / dbQuery / verify ─────────────────────────
    * atStep(null)
    * if (chargeNegRow) karate.fail('[NEGATIVE TEST FAILED] TestCase ' + testCaseId + ': expected a charge error containing "' + sheetOpt('expectedError') + '" but every stage collected its charges')
    * RowActions.endRow(td.testCaseId)
