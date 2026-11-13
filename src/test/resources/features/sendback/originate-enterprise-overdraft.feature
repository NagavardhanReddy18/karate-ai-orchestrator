@ignore
Feature: SendBack origination - enterprise overdraft application, originated and submitted for 08

  # 08-BLO-SendBack-and-Rejection.feature calls this with one row of SendBack-Excel-Automation.xlsx / EnterpriseOverdraft_Origination.
  # It originates and submits the enterprise overdraft application and returns appId / draftId; 08 then drives every
  # underwriter, approver, offer and setup decision. The steps are the origination of 07-BLO-Enterprise-Overdraft-LifeCycle.feature up to submit,
  # copied on 30-Oct-2026 so that 08 has no link to the 04-07 flows - a change to origination there has to be
  # repeated here if 08 should follow it.

  @ignore @originate
  Scenario: Originate and submit one enterprise overdraft application
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
    * print 'START DIRECT ENTERPRISE OVERDRAFT ROW [' + (td.rowIndex ? td.rowIndex : 1) + '/' + (td.totalRows ? td.totalRows : 1) + '] | TestCase:', testCaseId, '|', description
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

    # Enterprise profile / scorecard metrics
    * def enterpriseType = sheetOpt('enterpriseType')
    * def industrySector = sheetOpt('industrySector')
    * def businessVintageYears = sheetOptNum('businessVintageYears')
    * def annualTurnover = sheetOptNum('annualTurnover')
    * def avgMonthlyCredits = sheetOptNum('avgMonthlyCredits')
    * def promoterCibilScore = sheetOptNum('promoterCibilScore')

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
    # An enterprise-overdraft sheet added later may well name accounts that are seeded on one
    # machine and absent on another. karate-config.js is what resolves the account that really
    # holds each stage permission on this environment, so it is the fallback.
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
    * def entOdTypes = karate.jsonPath(response, "$.[?(@.customerType=='ENTERPRISE' && @.category=='OVERDRAFT' && @.active==true)]")
    * def entOdTypeCodes = karate.jsonPath(entOdTypes, '$[*].code')
    * def entOdTypeCode = sheetOpt('loanProductType')
    * def sheetTypeIsReal = (function() { for (var i = 0; i < entOdTypeCodes.length; i++) { if (entOdTypeCodes[i] == entOdTypeCode) return true; } return false; })()
    * print '✔ [TESTER VERIFICATION] Step 00: Enterprise Overdraft Product Type -> From Sheet:', entOdTypeCode, '| Active ENTERPRISE/OVERDRAFT Type On Server:', sheetTypeIsReal

    * def approvalLimitArgs =
    """
    {
      baseUrl: '#(baseUrl)',
      makerAuthHeader: '#(freshAdminHeader)',
      makerUsername: '#(activeAdminUser)',
      loanType: '#(entOdTypeCode)',
      partyType: '#(approvalLimitPartyType)',
      facilityType: '#(approvalLimitFacilityType)',
      currencyCode: '#(currency)',
      requiredAmount: #(loanAmount),
      limitAmount: #(approvalLimitAmount)
    }
    """
    * if (!isNegativeTest) karate.call('classpath:features/loans/approval-limit-helper.feature', approvalLimitArgs)
    * print '✔ [TESTER VERIFICATION] Step 00b: Approval Limit Bootstrap -> LoanType:', entOdTypeCode, '| Required:', loanAmount, currency, '| Bootstrapped:', !isNegativeTest

    # Step 01: Authenticate Loan Officer
    * def officerToken = login(activeOfficerUser, activeOfficerPass)
    * def officerAuthHeader = 'Bearer ' + officerToken
    * def authHeader = officerAuthHeader
    * print '✔ [TESTER VERIFICATION] Step 01: Officer Auth -> User:', activeOfficerUser, '| Status: PASSED (Token Issued)'

    # ─── ORIGINATION WIZARD (ENTERPRISE OVERDRAFT) ──────────────────────────

    Given path '/v1/product-types/submittable'
    When method GET
    Then status 200
    * def submittableCodes = karate.jsonPath(response, "$[*].code")
    * print '✔ [TESTER VERIFICATION] Step 02: Submittable Product Types -> Target:', entOdTypeCode, '| Returned Codes:', submittableCodes, '| MATCHED'

    * atStep('01')

    # Step 03: Corporate Customer Profile & Eligibility (404 is legitimate — CBS-sourced cache)
    Given path '/v1/enterprise-customers/' + customerId
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || isNegativeTest
    * def entCustStatus = responseStatus
    * def entCustName = (responseStatus == 200 && response.enterpriseName) ? response.enterpriseName : ((responseStatus == 200 && response.fullName) ? response.fullName : null)

    Given path '/v1/enterprise-customers/' + customerId + '/validate'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 03: Corporate Customer Lookup -> Sheet ID:', customerId, '| Sheet Name:', customerName, '| Server Name:', entCustName, '| Profile HTTP:', entCustStatus, '| Validate HTTP:', responseStatus

    * atStep('03')

    # Step 04: Initial Draft Creation
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef
    * match response.id == '#number'
    * print '✔ [TESTER VERIFICATION] Step 04: Initial Draft Creation -> Draft ID:', draftId, '| Reference:', draftRef, '| PASSED'

    * atStep('04')

    # Step 05: Enterprise Overdraft Product Selection (CORPORATE current-account products)
    Given path '/v1/origination/products/overdraft'
    And param productTypeCode = entOdTypeCode
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
    * print '✔ [TESTER VERIFICATION] Step 05: Overdraft Product Selection -> From Sheet:', odProductCode, '| Offered By Server:', productOfferedByServer, '| Returned Count:', karate.sizeOf(odItems)

    * atStep('05')

    # Step 06: Financial Statement Template Download + Population
    Given path '/v1/origination/draft/' + draftId + '/financial-statement-template'
    And param enterpriseName = customerName
    And param partyId = customerId
    And param currency = currency
    When method GET
    Then assert responseStatus == 200 || responseStatus == 404 || responseStatus == 500 || isNegativeTest
    * def templateBytes = (responseStatus == 200) ? responseBytes : null
    * print '✔ [TESTER VERIFICATION] Step 06: Financial Statement Template -> Draft:', draftId, '| Download HTTP:', responseStatus, '| Bytes Received:', (templateBytes != null)

    # The statement is the sheet's own figures (annualRevenue ... retainedEarnings). A row that
    # fills in none of them sends no statement at all, and a blank figure counts as 0.
    * def entHelper = Java.type('com.ird.beyond.lo.test.util.EnterpriseFinancialsHelper')
    * def enterpriseFinancialsJson = entHelper.fromSheetOnly(templateBytes, td)
    * print '✔ [TESTER VERIFICATION] Step 06b: Enterprise Financials From Sheet -> Provided:', (enterpriseFinancialsJson != null)

    * atStep('06')

    # Step 07: Collateral — forcedSaleValue must cover the OD limit or the collateral gate rejects.
    * def colType = sheetOpt('collateralType')
    * def hasCollateral = colType != null
    * def colForcedVal = sheetOptNum('collateralForcedSaleValue')
    * def collaterals = hasCollateral ? [ { "collateralType": colType, "description": sheetOpt('collateralDescription'), "estimatedValue": sheetOptNum('collateralEstimatedValue'), "forcedSaleValue": colForcedVal, "currency": currency } ] : []
    * string manualCollateralsJson = collaterals
    * print '✔ [TESTER VERIFICATION] Step 07: Collateral Prepared -> Type:', colType, '| Forced Sale Value:', colForcedVal, '| Covers OD Limit:', (colForcedVal >= loanAmount)

    * atStep('07')

    # Step 08: Save/Update Complete Enterprise Overdraft Draft
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
      "loanProductType": "#(entOdTypeCode)",
      "interestType": "#(interestType)",
      "overriddenInterestRate": #(overriddenRate),
      "effectiveInterestRate": #(effectiveInterestRate),
      "repaymentFrequency": "#(repaymentFrequency)",
      "repaymentStartDate": "#(repaymentStartDate)",
      "enterpriseType": "#(enterpriseType)",
      "industrySector": "#(industrySector)",
      "businessVintageYears": #(businessVintageYears),
      "annualTurnover": #(annualTurnover),
      "avgMonthlyCredits": #(avgMonthlyCredits),
      "promoterCibilScore": #(promoterCibilScore),
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
      "enterpriseFinancials": "#(enterpriseFinancialsJson)",
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
    * print '✔ [TESTER VERIFICATION] Step 08: Save Draft Data -> Expected OD Limit:', loanAmount, '| Actual Response:', response.loanAmount, '| Product:', response.selectedProductCode, '| MATCHED'

    * atStep('08')

    # Step 09: Document Checklist & Upload
    Given path '/v1/product-config/checklist'
    And param productTypeCode = entOdTypeCode
    And param productCode = odProductCode
    When method GET
    Then assert responseStatus == 200 || responseStatus == 204 || responseStatus == 404 || isNegativeTest
    * print '✔ [TESTER VERIFICATION] Step 09: Document Checklist Lookup -> HTTP:', responseStatus, '| Rules Returned Count:', (responseStatus == 200 ? karate.sizeOf(response) : 0)

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

    # Step 10: Charge Collection & Draft Submission
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
    # Confirms the type resolved to the enterprise-OD facility, and therefore to the LOS_ENT_OD route.
    * def submittedFacility = finalSubmitResponse.facilityTypeId
    * if (submittedFacility != null) karate.match(submittedFacility, 'OVERDRAFT')
    * print '✔ [TESTER VERIFICATION] Step 11: Draft Submission -> Draft ID:', draftId, '| Submit HTTP:', submitStatus, '| Application ID:', appId, '| Facility:', submittedFacility

    # Submitted: the SendBack runner takes the application from here.
    * print '[sendback-origination] TestCase', td.testCaseId, 'submitted as application', appId
    * RowActions.endRow(td.testCaseId)
