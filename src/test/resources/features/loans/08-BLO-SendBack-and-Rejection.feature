@loans @e2e @data-driven @send-back
Feature: Loan Send-Back, Resubmit & Rejection — row-chained runner over SendBack-Excel-Automation.xlsx

  # ── How this feature works ─────────────────────────────────────────────────
  #
  # One Excel row = ONE VISIT to an application. Rows run top to bottom and a row can
  # continue the application an earlier row left behind:
  #
  #   SB-01-A  originate + submit (04 columns)  -> underwriter sends back      -> PENDING_DOCUMENTS
  #   SB-01-B  continueFrom=SB-01-A, resubmit=Y -> UW forwards -> Approver 1 sends back -> PENDING_DOCUMENTS
  #   SB-01-C  continueFrom=SB-01-B, resubmit=Y -> UW forwards -> Approver 1 approves -> offer -> setup -> COMPLETED
  #
  # The runner (first scenario) loops the rows itself and keeps a `chain` map
  # { testCaseId -> { appId, draftId, draftRef, td, status, ranAt } } so a later row can pick up
  # the application id its `continueFrom` row produced. `applicationId` (numeric) resumes a
  # LIVE application by hand and wins over `continueFrom`.
  #
  # The chain is SAVED to target/sendback-chain.json after every row, so rows can be run ONE AT
  # A TIME (run=Y on a single row per execution): SB-01-A today, SB-01-B in the next execution,
  # and so on. A continuation row looks in the current run first, then in the saved file. A row
  # that fails removes its own entry so nothing continues a half-built application. `mvn clean`
  # deletes the file (re-run the A row, or put the application id in applicationId).
  #
  # Server rules the sheet must respect (verified in beyond-lo-core, 2026-09-21):
  #   - UW REQUEST_ADDITIONAL_DOCS / RETURN_FOR_DOCS and approver REQUEST_DOCS put the
  #     application in PENDING_DOCUMENTS and release the claim to the officer pool.
  #   - The officer must claim, then POST /v1/loans/{id}/recall (draft back to step 3,
  #     application IN_PROGRESS, workflow instance deleted), edit, then submit the draft.
  #     Amount and tenure stay LOCKED (409 on change); repayment frequency / rate / notes / documents can change.
  #   - Every resubmit restarts the workflow at intake, so an underwriter round ALWAYS follows a
  #     resubmit — even after an approver send-back. Fill uwAction on every resubmit row.
  #   - Approver RETURN sends the case back to the UNDERWRITER (not the officer): status UNDER_REVIEW,
  #     phase UNDERWRITER_APPROVE, claim released, UW decision cleared. The next row needs NO resubmit:
  #     just uwAction (forward again, or REQUEST_ADDITIONAL_DOCS to pull the officer in) — see SB-05 / SB-06.
  #
  # Column groups (see the Notes sheet of the workbook):
  #   control      run, testCaseId, description, continueFrom, applicationId, originateFeature, originateRow
  #   originate    originateFeature RETAIL | ENTERPRISE | OVERDRAFT | ENTERPRISE_OD + originateRow (a testCaseId of this
  #                workbook's matching *_Origination sheet, any run flag): the feature in sendback/ originates and submits
  #                that application - retail or enterprise loan, retail or enterprise overdraft - and 08 drives every
  #                decision after it. Only the origination row's data is used. Setup follows the application: a loan gets
  #                its CBS account through create-account, an overdraft its OD account, limit and debit rate.
  #                Blank = 08's own retail origination from the row's 04 columns. 08 has no link to the 04-07 flows.
  #                Blank = 08's own retail origination.
  #   origination  the retail origination columns (the same names as the retail lifecycle sheet; used only when a row
  #                originates with 08's own retail origination)
  #   resubmit     resubmit, resubmitDocument{Type,Name,Status,Comment}, amend{LoanTerm,TermFrequency,RepaymentFrequency,InterestRate,DisbursementNotes}
  #   underwriter  underwriterUsername, uwAction, uwComment, uwRequestedDocs, notifyOfficer, notifyCustomer
  #   approver     approver1Username, approver2Username, ccUsername, approverRole, approverPriorVotes, approverAction, approverComment
  #   reject flags rejectAtUnderwriter / rejectAtApprover / rejectAtOfferIssue / rejectAtOfferAcceptance (Y/N), rejectReason
  #                The flags only MARK the row; the actions themselves are the sheet's, like every other stage:
  #                  rejectAtUnderwriter     -> uwAction = REJECT                         -> REJECTED
  #                  rejectAtApprover        -> approverAction = DECLINE                  -> REJECTED
  #                  rejectAtOfferIssue      -> approved, issuerAction = CANCEL           -> CANCELLED
  #                  rejectAtOfferAcceptance -> offer issued, acceptorAction = DECLINE    -> OFFER_DECLINED
  #                rejectReason is sent as the reject / decline / cancel reason.
  #   phase actions issuerAction ISSUE | CANCEL, acceptorAction ACCEPT | DECLINE, setupAction CREATE_ACCOUNT -
  #                required on every row whose application reaches that stage (never inherited).
  #   charges      applicationCharges / assessmentCharges / offerCharges / offerAcceptanceCharges / setupCharges name
  #                the configured charges each stage's user collects (stage-charges.js); a charge
  #                that will not settle is waived when chargeFallbackAction = WAIVE (chargeWaiveReason as the reason).
  #   assessment   the underwriter opens the assessment and the server's method decides, as in 04: an application the
  #                scorecard AUTO-approves has no underwriter or approver decision to take, so only
  #                uwAction = APPROVE_TO_APPROVER / approverAction = APPROVE are accepted for it (and skipped).
  #   sheet-only   nothing is defaulted here: every action, comment, reason, document, charge mode and
  #                setup value a row needs must be in the row (or in the row it continues).
  #   offer/setup  skipIssueOffer, skipOfferAccept, skipLoanSetup, issuer/acceptor/setup usernames, offer* columns
  #   check        expectedStatus, store, dbQuery, verify
  #
  # Run:
  #   mvn -o test -Dkarate.env=test -Dkarate.options="classpath:features/loans/08-BLO-SendBack-and-Rejection.feature"
  #
  # Karate note: every conditional in this file is a single-line `* if (...) karate.xxx(...)` or a
  # `cond ? karate.call(...) : null`. Multi-line blocks after `if` are NOT valid Karate and fail with
  # "no step-definition method match found" — that is why each phase lives in its own @ignore scenario.

  # ═══════════════════════════════════════════════════════════════════════════
  # Runner — loops rows in sheet order and carries the application chain forward
  # ═══════════════════════════════════════════════════════════════════════════
  Scenario: Run send-back flow for all enabled rows (Sheet: SendBack_Flow)
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/SendBack-Excel-Automation.xlsx')
    * def rawRows = ExcelDataLoader.load(excelPath, 'SendBack_Flow')
    * def annotateRows = function(rList) { if (rList == null) return []; var n = rList.length; for (var i = 0; i < n; i++) { rList[i].rowIndex = i + 1; rList[i].totalRows = n; } return rList; }
    * def rows = annotateRows(rawRows)
    * def rowCount = rows.length
    * print '======================================================='
    * print '[08-SENDBACK] Total rows enabled (run=Y) in SendBack_Flow:', rowCount
    * print '======================================================='

    # chain: testCaseId -> what that row left behind. Loaded from target/sendback-chain.json (written
    # after every row) so a continuation row can be run in a LATER execution than the row it
    # continues. failed: testCaseIds whose row failed in THIS run (their continuations are skipped
    # rather than run against a half-built application).
    * def JFile = Java.type('java.io.File')
    * def JFiles = Java.type('java.nio.file.Files')
    * def chainPath = 'target/sendback-chain.json'
    * def chainAbs = new JFile(chainPath).getAbsolutePath()
    * def chain = new JFile(chainPath).exists() ? karate.read('file:' + chainPath) : {}
    * def saveChain = function() { new JFile(chainPath).getParentFile().mkdirs(); JFiles.write(new JFile(chainPath).toPath(), karate.pretty(chain).getBytes('UTF-8')); }
    * def describeSaved = function() { var ks = karate.keysOf(chain); var out = []; for (var i = 0; i < ks.length; i++) { var c = chain[ks[i]]; if (c != null) out.push(ks[i] + ' -> app ' + c.appId + ' (' + c.draftRef + ', ' + c.status + ', ran ' + c.ranAt + ')'); } return out; }
    * print '[08-SENDBACK] chain file:', chainAbs
    * print '[08-SENDBACK] rows remembered from earlier runs:', describeSaved()
    * def failed = []
    * def skipped = []
    * def blank = function(v) { return v == null || (typeof v === 'string' && v.trim() == '') }
    * def runRow =
    """
    function(row) {
      var id = row.testCaseId;
      var from = blank(row.continueFrom) ? null : row.continueFrom.toString().trim();
      var hasExplicitApp = !blank(row.applicationId);
      if (from != null && !hasExplicitApp && failed.indexOf(from) >= 0) {
        karate.log('[08-SENDBACK] SKIP', id, '- its continueFrom row', from, 'failed');
        skipped.push(id + ' (continueFrom ' + from + ' failed)');
        failed.push(id);
        return;
      }
      if (from != null && !hasExplicitApp && chain[from] == null) {
        karate.log('[08-SENDBACK] SKIP', id, '- continueFrom row', from, 'has not run yet: not in this execution and not in', chainAbs, '(run', from, 'first with run=Y, or put the application id in applicationId)');
        skipped.push(id + ' (continueFrom ' + from + ' not run)');
        failed.push(id);
        return;
      }
      if (from != null && !hasExplicitApp) {
        var p = chain[from];
        karate.log('[08-SENDBACK] ROW', id, 'continues', from, '-> application', p.appId, '(' + p.draftRef + ')', 'left in status', p.status, 'by the run at', p.ranAt);
      }
      var arg = karate.merge(row, { chain: chain });
      try {
        var r = karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@sendBackRow', arg);
        chain[id] = { appId: r.appId, draftId: r.draftId, draftRef: r.draftRef, td: r.tdOut, status: r.finalRowStatus, ranAt: new Date().toISOString() };
        saveChain();
        karate.log('[08-SENDBACK] DONE', id, '-> appId', r.appId, 'ref', r.draftRef, 'status', r.finalRowStatus, '| saved to', chainPath);
      } catch (e) {
        karate.log('[08-SENDBACK] FAILED', id, ':', e);
        chain[id] = null;
        saveChain();
        failed.push(id);
        skipped.push(id + ' (FAILED: ' + e + ')');
      }
    }
    """
    * karate.forEach(rows, runRow)
    * print '[08-SENDBACK] chain now (also in ' + chainPath + '):', describeSaved()
    * if (rowCount == 0) karate.log('[08-SENDBACK] No run=Y rows in SendBack_Flow — nothing to do')
    * if (skipped.length > 0) karate.fail('[08-SENDBACK] ' + skipped.length + ' row(s) failed or were skipped: ' + skipped)

  # ═══════════════════════════════════════════════════════════════════════════
  # @sendBackRow — one visit to an application, driven by one Excel row
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @sendBackRow
  Scenario: Run one send-back row
    * def rowIn = __arg
    * def chain = (rowIn.chain != null) ? rowIn.chain : {}
    * def val = function(v) { return (v == null || (typeof v === 'string' && v.trim() == '')) ? null : (typeof v === 'string' ? v.trim() : v) }
    * def flag = function(v) { var s = val(v); return s === true || (s != null && ['Y','YES','TRUE'].indexOf(s.toString().toUpperCase()) >= 0) }

    * print '==================================================================='
    * print 'START ROW [' + (rowIn.rowIndex ? rowIn.rowIndex : 1) + '/' + (rowIn.totalRows ? rowIn.totalRows : 1) + '] | TestCase:', rowIn.testCaseId, '| continueFrom:', val(rowIn.continueFrom), '| applicationId:', val(rowIn.applicationId), '| this run has', (rowIn.totalRows ? rowIn.totalRows : 1), 'row(s) with run=Y'
    * print '  ', rowIn.description
    * print '==================================================================='

    # ── Which application does this row work on? ────────────────────────────
    * def explicitAppId = (val(rowIn.applicationId) != null) ? Math.round(Number(rowIn.applicationId)) : null
    * def contFrom = val(rowIn.continueFrom)
    * def prev = (explicitAppId == null && contFrom != null && chain[contFrom] != null) ? chain[contFrom] : null
    * if (explicitAppId == null && contFrom != null && prev == null) karate.fail('Row ' + rowIn.testCaseId + ' continues ' + contFrom + ' but that row produced nothing in this run')
    * def isNewApp = (explicitAppId == null && prev == null)

    # Effective row: a continuation row inherits the ORIGINATION columns (and any amendments already
    # applied) from the row it continues; its own non-blank cells win. Phase columns (uwAction,
    # approverAction, resubmit, expectedStatus ...) are never inherited.
    * def ORIG_KEYS = ['adminUsername','originateFeature','originateRow','officerUsername','loanCategory','loanProductType','customerTypeSelected','customerId','customerName','branch','accountOpenBranch','loanPurpose','effectiveInterestRate','loanStartDate','repaymentStartDate','paymentType','feeAccountNumber','selectedCollaterals','collateralAssignmentDetails','commitmentId','docSignedState','uploadDocumentPhase','chargeCollectionMode','chargeWaiveReason','setupSettlementMode','setupOfficerNotes','loanTerm','termFrequency','loanAmountCurrency','totalAmount','totalAmountCurrency','customerContribution','loanAmount','monthlyGrossIncome','existingEmiObligations','employmentType','employerName','periodOfEmployment','otherIncome','monthlyLivingExpenses','incomeDetails','expenseDetails','coApplicants','extendedData','selectedProductCode','selectedProductName','interestType','repaymentFrequency','repaymentType','overriddenInterestRate','collateralType','collateralDescription','collateralEstimatedValue','collateralForcedSaleValue','settlementMode','repaymentAccountNumber','feeFundingAccountNumber','chargeFallbackAction','applicationCharges','assessmentCharges','offerAcceptanceCharges','offerCharges','setupCharges','disbursementMode','disbursementDate','disbursementAccountNumber','disbursementNotes','approvalLimitPartyType','approvalLimitFacilityType','approvalLimitAmount','underwriterUsername','approver1Username','approver2Username','ccUsername','issuerUsername','acceptorUsername','setupUsername','offerValidityDate','offerRateAdjustment','offerPrincipalReduction','notifyOfficer','notifyCustomer']
    * def mergeRow =
    """
    function(base, cur) {
      var out = {};
      if (base != null) { for (var i = 0; i < ORIG_KEYS.length; i++) { var k = ORIG_KEYS[i]; if (base[k] != null) out[k] = base[k]; } }
      var ck = karate.keysOf(cur);
      for (var j = 0; j < ck.length; j++) { var key = ck[j]; if (key == 'chain') continue; var v = cur[key]; var isBlank = (v == null || (typeof v === 'string' && v.trim() == '')); if (!isBlank || out[key] === undefined) out[key] = v; }
      return out;
    }
    """
    * def td = mergeRow(prev != null ? prev.td : null, rowIn)

    # originateFeature RETAIL | ENTERPRISE | OVERDRAFT | ENTERPRISE_OD + originateRow (a testCaseId of this workbook's
    # matching *_Origination sheet, whatever its run flag): the feature in sendback/ originates and submits the
    # application - enterprise financials, overdraft facility, its charges - and hands it back; 08 then drives the
    # decisions. The row's own non-blank cells win over the origination row (phase columns, actions, expectedStatus ...).
    # Blank = 08's own retail origination from the row's 04 columns.
    * def ORIGINATORS =
    """
    {
      RETAIL:        { feature: 'sendback/originate-retail.feature',               sheet: 'Retail_Origination' },
      ENTERPRISE:    { feature: 'sendback/originate-enterprise.feature',           sheet: 'Enterprise_Origination' },
      OVERDRAFT:     { feature: 'sendback/originate-overdraft.feature',            sheet: 'Overdraft_Origination' },
      ENTERPRISE_OD: { feature: 'sendback/originate-enterprise-overdraft.feature', sheet: 'EnterpriseOverdraft_Origination' }
    }
    """
    * def originFeature = val(td.originateFeature) == null ? null : ('' + val(td.originateFeature)).toUpperCase()
    * if (originFeature != null && ORIGINATORS[originFeature] == null) karate.fail('Row ' + td.testCaseId + ': originateFeature "' + td.originateFeature + '" is not one of RETAIL, ENTERPRISE, OVERDRAFT, ENTERPRISE_OD')
    * if (originFeature != null && val(td.originateRow) == null) karate.fail('Row ' + td.testCaseId + ': originateFeature ' + originFeature + ' needs originateRow (a testCaseId of the ' + ORIGINATORS[originFeature].sheet + ' sheet)')
    * def originator = originFeature == null ? null : ORIGINATORS[originFeature]
    * def originRow = originator == null ? null : Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader').loadRow(karate.toAbsolutePath('classpath:features/loans/testdata/SendBack-Excel-Automation.xlsx'), originator.sheet, '' + val(td.originateRow))
    * def overlay =
    """
    function(base, top) {
      var out = {};
      var bk = karate.keysOf(base);
      // Only the origination row's ORIGINATION data is taken: its identity, expectations and stage decisions are
      // its own - a blank action here means "stop before that stage", never "do what the origination row does".
      var NOT_BORROWED = ['run', 'testCaseId', 'description', 'expectedStatus', 'expectedError', 'expectedCode', 'continueFrom', 'applicationId',
        'skipUw', 'skipApprover1', 'skipApprover2', 'skipCc', 'skipIssueOffer', 'skipOfferAccept', 'skipLoanSetup',
        'uwAction', 'uwComment', 'uwRequestedDocs', 'approverRole', 'approverPriorVotes', 'approverAction', 'approver1Action', 'approver2Action', 'approverComment',
        'issuerAction', 'acceptorAction', 'offerDeclineReason', 'setupAction', 'resubmit',
        'rejectAtUnderwriter', 'rejectAtApprover', 'rejectAtOfferIssue', 'rejectAtOfferAcceptance', 'rejectReason'];
      // store / dbQuery / verify (and their AfterStepNN forms) check the origination row's own run - e.g. its CBS account
      for (var i = 0; i < bk.length; i++) if (NOT_BORROWED.indexOf(bk[i]) < 0 && !/^(store|dbQuery|verify)/.test(bk[i])) out[bk[i]] = base[bk[i]];
      var tk = karate.keysOf(top);
      for (var j = 0; j < tk.length; j++) { var k = tk[j]; var v = top[k]; var isBlank = (v == null || (typeof v === 'string' && v.trim() == '')); if (!isBlank || out[k] === undefined) out[k] = v; }
      return out;
    }
    """
    * def td = originRow == null ? td : overlay(originRow, td)

    * def RowActions = Java.type('com.ird.beyond.lo.test.util.RowActions')
    * RowActions.beginRow(td.testCaseId)
    * def atStep = function(step) { return RowActions.runAnchor(td, step, karate.get('response'), function(n){ return karate.get(n) }) }

    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }

    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn
    * def getCred = function(excelVal, defaultVal) { return (excelVal && excelVal.toString().trim() != '') ? excelVal.toString().trim() : defaultVal }

    * def activeAdminUser   = getCred(td.adminUsername, defaultAdminUsername)
    * def activeAdminPass   = defaultAdminPassword
    * def activeOfficerUser = getCred(td.officerUsername, defaultOfficerUsername)
    * def activeOfficerPass = defaultOfficerPassword

    # ── Phase 1: originate (new application only) ───────────────────────────
    * def feeAcct = (val(td.feeFundingAccountNumber) != null) ? val(td.feeFundingAccountNumber).toString() : (val(td.repaymentAccountNumber) != null ? val(td.repaymentAccountNumber).toString() : null)
    * def handoff = (isNewApp && originator != null) ? karate.call('classpath:features/loans/' + originator.feature + '@originate', karate.merge(td, { expectedStatus: null, expectedError: null, expectedCode: null })) : null
    # (08's expectedStatus is this row's end state, not a refusal the origination should expect - so it is not passed on)
    * if (handoff != null && handoff.appId == null) karate.fail('Row ' + td.testCaseId + ': ' + originator.feature + ' did not hand back an application for ' + td.originateRow)
    * if (handoff != null) karate.log('[SB] application', handoff.appId, 'originated and submitted by', originator.feature, 'from its row', td.originateRow)
    * def orig = (isNewApp && originator == null) ? karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@originate', { td: td, activeAdminUser: activeAdminUser, activeAdminPass: activeAdminPass, activeOfficerUser: activeOfficerUser, activeOfficerPass: activeOfficerPass, feeAcct: feeAcct }) : null
    * def officerAuthHeader = (orig != null) ? orig.officerAuthHeader : ('Bearer ' + login(activeOfficerUser, activeOfficerPass))
    * def authHeader = officerAuthHeader
    * def appId   = isNewApp ? (orig != null ? orig.appId : handoff.appId) : (explicitAppId != null ? explicitAppId : prev.appId)
    * def draftId = isNewApp ? (orig != null ? orig.draftId : handoff.draftId) : (prev != null ? prev.draftId : null)
    * match appId == '#notnull'

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def appNow = response
    * def draftRef = appNow.applicationNumber
    # A manually resumed application has no earlier row to inherit from: read the wizard draft back
    # from the server and use it for every origination column the row left blank.
    * def draftByRef = (!isNewApp && prev == null) ? karate.http(baseUrl + '/v1/origination/draft/ref/' + draftRef).header('Authorization', officerAuthHeader).get() : null
    * def draftSrc = (draftByRef != null && draftByRef.status == 200) ? draftByRef.body : {}
    * def FILL_KEYS = ['loanCategory','loanProductType','customerTypeSelected','customerId','customerName','branch','loanPurpose','loanTerm','termFrequency','loanAmountCurrency','totalAmount','totalAmountCurrency','customerContribution','loanAmount','monthlyGrossIncome','existingEmiObligations','selectedProductCode','selectedProductName','interestType','repaymentFrequency','repaymentType','overriddenInterestRate','settlementMode','repaymentAccountNumber','feeFundingAccountNumber','disbursementMode','disbursementDate','disbursementAccountNumber','disbursementNotes']
    * def appFallback = { loanAmount: '#(appNow.loanAmount)', loanAmountCurrency: '#(appNow.loanAmountCurrency)', totalAmount: '#(appNow.totalAmount)', loanTerm: '#(appNow.loanTerm)', termFrequency: '#(appNow.termFrequency)', repaymentFrequency: '#(appNow.repaymentFrequency)', customerId: '#(appNow.customerId)', selectedProductCode: '#(appNow.selectedProductCode)', selectedProductName: '#(appNow.selectedProductName)', loanProductType: '#(appNow.loanType)', loanCategory: '#(appNow.segment)', interestType: '#(appNow.interestType)', overriddenInterestRate: '#(appNow.effectiveInterestRate > 0 ? appNow.effectiveInterestRate : null)' }
    * def fillFromServer = function() { for (var i = 0; i < FILL_KEYS.length; i++) { var k = FILL_KEYS[i]; if (val(td[k]) != null) continue; if (draftSrc[k] != null) { td[k] = draftSrc[k]; } else if (appFallback[k] != null) { td[k] = appFallback[k]; } } }
    * if (!isNewApp && prev == null) fillFromServer()
    * if (!isNewApp && prev == null) karate.set('draftId', draftSrc.id != null ? draftSrc.id : draftId)
    * if (!isNewApp && prev == null && val(td.approverAction) != null && val(td.approverAction).toString().toUpperCase() == 'APPROVE' && !(Number(td.overriddenInterestRate) > 0)) karate.fail('Row ' + td.testCaseId + ' resumes application ' + appId + ' and approves it, but no interest rate is known (server effectiveInterestRate=' + appNow.effectiveInterestRate + '). Fill overriddenInterestRate in the row - the approver vote carries it and offer issue refuses without one.')
    * def feeAcct = (val(td.feeFundingAccountNumber) != null) ? val(td.feeFundingAccountNumber).toString() : (val(td.repaymentAccountNumber) != null ? val(td.repaymentAccountNumber).toString() : null)
    * def chargeFallbackAction = val(td.chargeFallbackAction)
    * print '✔ [SB] Working on application', appId, '| ref', draftRef, '| status now:', appNow.status, '| new:', isNewApp
    * atStep('11')

    # ── Phase 2: officer resubmit (claim -> recall -> upload -> amend -> submit) ──
    * def doResubmit = flag(td.resubmit)
    * def TERMINAL = ['COMPLETED', 'REJECTED', 'CANCELLED', 'WITHDRAWN', 'EXPIRED']
    * if (doResubmit && TERMINAL.indexOf(appNow.status) >= 0) karate.fail('Row ' + td.testCaseId + ': resubmit=Y but application ' + appId + ' (' + draftRef + ') is already ' + appNow.status + (prev != null ? ' - it was left by row ' + contFrom + ' run at ' + prev.ranAt : '') + '. Re-run the originating row (run=Y) to get a fresh application, or point applicationId at a PENDING_DOCUMENTS application.')
    * if (doResubmit && appNow.status != 'PENDING_DOCUMENTS' && appNow.status != 'IN_PROGRESS') karate.log('[SB] WARNING: resubmit=Y but application', appId, 'is', appNow.status, '- recall will be attempted anyway')
    * def resub = doResubmit ? karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@resubmit', { td: td, appId: appId, draftRef: draftRef, officerAuthHeader: officerAuthHeader, activeAdminUser: activeAdminUser, activeAdminPass: activeAdminPass, feeAcct: feeAcct }) : null
    * if (resub != null) karate.set('td', resub.tdOut)
    * if (resub != null) karate.set('draftId', resub.recalledDraftId)

    # ── Reject flags: one Y decides where the application is rejected ─────────
    * def rejUw   = flag(td.rejectAtUnderwriter)
    * def rejApp  = flag(td.rejectAtApprover)
    * def rejIss  = flag(td.rejectAtOfferIssue)
    * def rejAcc  = flag(td.rejectAtOfferAcceptance)
    * def rejCount = (rejUw ? 1 : 0) + (rejApp ? 1 : 0) + (rejIss ? 1 : 0) + (rejAcc ? 1 : 0)
    * if (rejCount > 1) karate.fail('Row ' + td.testCaseId + ': only ONE of rejectAtUnderwriter / rejectAtApprover / rejectAtOfferIssue / rejectAtOfferAcceptance may be Y')
    * def rejectReason = (val(td.rejectReason) != null) ? td.rejectReason.toString() : null
    * if (rejUw && (val(td.uwAction) == null || val(td.uwAction).toString().toUpperCase() != 'REJECT')) karate.fail('Row ' + td.testCaseId + ': rejectAtUnderwriter=Y needs uwAction = REJECT in the row')
    * if (rejApp && (val(td.approverAction) == null || val(td.approverAction).toString().toUpperCase() != 'DECLINE')) karate.fail('Row ' + td.testCaseId + ': rejectAtApprover=Y needs approverAction = DECLINE in the row')
    * if ((rejIss || rejAcc) && (val(td.approverAction) == null || val(td.approverAction).toString().toUpperCase() != 'APPROVE')) karate.fail('Row ' + td.testCaseId + ': rejectAtOfferIssue / rejectAtOfferAcceptance need the row to reach APPROVED - fill uwAction and approverAction = APPROVE')
    * if (rejIss && (val(td.issuerAction) == null || val(td.issuerAction).toString().toUpperCase() != 'CANCEL')) karate.fail('Row ' + td.testCaseId + ': rejectAtOfferIssue=Y needs issuerAction = CANCEL in the row')
    * if (rejAcc && (val(td.acceptorAction) == null || val(td.acceptorAction).toString().toUpperCase() != 'DECLINE')) karate.fail('Row ' + td.testCaseId + ': rejectAtOfferAcceptance=Y needs acceptorAction = DECLINE in the row')
    * if (rejCount > 0) karate.log('[SB] reject flag ->', (rejUw ? 'underwriter REJECT' : rejApp ? 'approver DECLINE' : rejIss ? 'cancel at offer issue' : 'decline at offer acceptance'), '| uwAction', td.uwAction, '| approverAction', td.approverAction, '| reason', rejectReason)

    # ── Phase 3: underwriter ─────────────────────────────────────────────────
    * def uwAction = (val(td.uwAction) != null) ? val(td.uwAction).toString().toUpperCase() : null
    * def uwRes = (uwAction != null) ? karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@underwriter', { td: td, appId: appId, uwAction: uwAction, feeAcct: feeAcct, chargeFallbackAction: chargeFallbackAction }) : null
    * atStep('15')

    # ── Phase 4: approver ────────────────────────────────────────────────────
    * def approverAction = (val(td.approverAction) != null) ? val(td.approverAction).toString().toUpperCase() : null
    # The scorecard AUTO-approved the application at assessment: no approver decision exists to take.
    * def autoApprovedApp = uwRes != null && uwRes.autoApproved == true
    * if (autoApprovedApp && approverAction != null && approverAction != 'APPROVE') karate.fail('Row ' + td.testCaseId + ': the server AUTO-APPROVED application ' + appId + ' at assessment, so approverAction ' + approverAction + ' cannot be taken - use a product whose assessment method is MANUAL for approver decisions')
    * if (autoApprovedApp && approverAction != null) karate.log('[SB] application', appId, 'was AUTO-APPROVED at assessment - approver stage skipped')
    * def appRes = (approverAction != null && !autoApprovedApp) ? karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@approver', { td: td, appId: appId, approverAction: approverAction }) : null
    * atStep('16')

    # ── Phase 5: offer / acceptance / setup — only once the application is APPROVED ──
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def statusBeforePost = response.status
    * def doPost = (statusBeforePost == 'APPROVED')
    * def postRes = doPost ? karate.call('classpath:features/loans/08-BLO-SendBack-and-Rejection.feature@postApproval', { td: td, appId: appId, feeAcct: feeAcct, chargeFallbackAction: chargeFallbackAction, officerAuthHeader: officerAuthHeader, activeAdminUser: activeAdminUser, activeAdminPass: activeAdminPass }) : null
    * def generatedCbsAccountNo = (postRes != null) ? postRes.generatedCbsAccountNo : null
    * atStep('19')

    # ── End of row: assert expectedStatus, hand results back to the runner ──
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def finalRowStatus = response.status
    * def expectedStatus = val(td.expectedStatus)
    * expect(expectedStatus != null, finalRowStatus, (expectedStatus != null ? expectedStatus.toString().toUpperCase() : null), 'expectedStatus ' + td.testCaseId)
    * def tdOut = td
    * print '================================================================'
    * print '✔ [SB] ROW DONE       :', td.testCaseId
    * print '✔ Application ID       :', appId, '| ref:', draftRef
    * print '✔ Status at row end    :', finalRowStatus, '| Expected:', (expectedStatus != null ? expectedStatus : '(none)')
    * print '✔ CBS account          :', (generatedCbsAccountNo != null ? generatedCbsAccountNo : 'n/a')
    * print '================================================================'

    * def customerId = td.customerId
    * def finalStatus = finalRowStatus
    * atStep(null)
    * RowActions.endRow(td.testCaseId)
    * def logout = function(token) { if (token) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: token }) }
    * logout(officerAuthHeader)

  # ═══════════════════════════════════════════════════════════════════════════
  # @originate — 04 Steps 01-11: approval-limit bootstrap, wizard lookups, draft, document, submit
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @originate
  Scenario: Originate and submit a new application from the row's 04 columns
    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }
    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn

    # Approval-limit bootstrap (idempotent per row) — same as 04
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
    * karate.call('classpath:features/loans/approval-limit-helper.feature', approvalLimitArgs)

    # Step 01: Officer
    * def officerToken = login(activeOfficerUser, activeOfficerPass)
    * def officerAuthHeader = 'Bearer ' + officerToken
    * def authHeader = officerAuthHeader
    * print '✔ [SB-ORIG] Step 01: Officer authenticated:', activeOfficerUser

    # Step 02: Submittable product types + facility fields
    Given path '/v1/product-types/submittable'
    When method GET
    * def submittableCodes = karate.jsonPath(response, "$[*].code")
    * print '✔ [SB-ORIG] Step 02: Submittable product types:', submittableCodes, '| target:', td.loanProductType
    Given path '/v1/product-types/' + td.loanProductType + '/fields'
    When method GET
    Then status 200

    # Step 03: Customer
    Given path '/v1/origination/customers/' + td.customerId
    When method GET
    Then status 200
    * def custResp = response
    * match custResp.customerId == td.customerId
    * expect(td.customerName && custResp.fullName, custResp.fullName, td.customerName, 'customerName')
    * print '✔ [SB-ORIG] Step 03: Customer', td.customerId, '->', custResp.fullName

    # Step 04 / 05: purposes, eligible products, base codes
    Given path '/v1/product-types/' + td.loanProductType + '/purposes'
    When method GET
    Then status 200
    Given path '/v1/origination/products/eligible'
    And param currency = td.loanAmountCurrency
    And param facilityTypeId = td.approvalLimitFacilityType
    When method GET
    Then status 200
    Given path '/v1/origination/interest/base-codes'
    When method GET
    Then status 200

    # Step 06: Draft
    Given path '/v1/origination/draft'
    When method POST
    Then status 201
    * def draftId = response.id
    * def draftRef = response.applicationRef
    * print '✔ [SB-ORIG] Step 06: Draft', draftId, '| ref', draftRef

    * def calcTermMonths = (td.termFrequency == 'YEARS' ? td.loanTerm * 12 : td.loanTerm)
    # rateId and repaymentType come from the CBS sub-product configuration, as the UI's Interest & Schedule
    # step sends them (same as 04 Step 06b): rateId = the product's default rate for the interest type, and
    # repaymentType = the product's CBS letter code (e.g. C / R / K). Without them CBS answers 503, and the
    # draft has no rateId, so Loan Setup cannot reach CBS later.
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
    * def isManualProduct = cbsProduct.repaymentTypeDesc == 'Manual Schedule'
    * if (!schedRateId) karate.log('[SB-ORIG] product', td.selectedProductCode, 'has no rate id in the sub-product configuration LO holds - CBS will refuse the schedule')
    * def genRequest = { loanAmount: '#(td.loanAmount)', currency: '#(td.loanAmountCurrency)', termMonths: '#(calcTermMonths)', annualInterestRate: '#(td.overriddenInterestRate)', repaymentFrequency: '#(td.repaymentFrequency)', productCode: '#(td.selectedProductCode)', repaymentType: '#(schedRepaymentType)', rateId: '#(schedRateId)', customerId: '#(td.customerId)', applicationRef: '#(draftRef)' }
    * def schedFirstRepay = td.repaymentStartDate ? ('' + td.repaymentStartDate).substring(0, 10) : null
    * def schedLoanStart = td.loanStartDate ? ('' + td.loanStartDate).substring(0, 10) : null
    * if (schedFirstRepay) karate.set('genRequest', karate.merge(genRequest, { firstRepaymentDate: schedFirstRepay }))
    * if (schedLoanStart) karate.set('genRequest', karate.merge(genRequest, { loanStartDate: schedLoanStart }))
    * if (isManualProduct && td.autoPopulationMethod) karate.set('genRequest', karate.merge(genRequest, { autoPopulationMethod: td.autoPopulationMethod }))
    Given path '/v1/origination/schedule/generate'
    And request genRequest
    When method POST
    # Origination is a positive flow: it needs a generated schedule, so 503 CBS_UNAVAILABLE fails the row.
    * if (responseStatus != 200) karate.fail('[SCHEDULE GENERATION FAILED] TestCase ' + td.testCaseId + ': HTTP ' + responseStatus + ' ' + karate.toString(response))
    * print '✔ [SB-ORIG] Step 06b: Schedule generated -> product', td.selectedProductCode, '| rateId', schedRateId, '| repaymentType', schedRepaymentType, '| installments', karate.sizeOf(response)

    # Step 07 / 08: exposure + collateral
    Given path '/v1/origination/customers/' + td.customerId + '/in-flight-exposure'
    When method GET
    Then assert responseStatus == 200 || responseStatus == 503
    Given path '/v1/origination/customers/' + td.customerId + '/commitments'
    When method GET
    Then status 200
    * def hasCollateral = td.collateralType && td.collateralType != ''
    * def retailCollateralList = hasCollateral ? [ { "collateralType": td.collateralType, "description": td.collateralDescription, "estimatedValue": td.collateralEstimatedValue, "forcedSaleValue": td.collateralForcedSaleValue, "currency": td.loanAmountCurrency } ] : []
    * string manualCollateralsJson = retailCollateralList

    # Step 09: Save draft with the row's data, exactly as the row gives it (same body as 04)
    * def sheetText = function(v) { return (v == null || v.toString().trim() == '') ? null : v.toString().trim() }
    * def extendedData = sheetText(td.extendedData) != null ? karate.fromString(sheetText(td.extendedData)) : null
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
      "branch": "#(td.branch)",
      "accountOpenBranch": "#(td.accountOpenBranch)",
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
      "overriddenInterestRate": #(td.overriddenInterestRate),
      "effectiveInterestRate": #(td.effectiveInterestRate),
      "loanStartDate": "#(td.loanStartDate)",
      "repaymentFrequency": "#(td.repaymentFrequency)",
      "repaymentStartDate": "#(td.repaymentStartDate)",
      "employmentType": "#(td.employmentType)",
      "employerName": "#(td.employerName)",
      "periodOfEmployment": #(td.periodOfEmployment),
      "monthlyGrossIncome": #(td.monthlyGrossIncome),
      "otherIncome": #(td.otherIncome),
      "monthlyLivingExpenses": #(td.monthlyLivingExpenses),
      "existingEmiObligations": #(td.existingEmiObligations),
      "incomeDetails": "#(td.incomeDetails)",
      "expenseDetails": "#(td.expenseDetails)",
      "coApplicants": "#(td.coApplicants)",
      "extendedData": #(extendedData),
      "manualCollaterals": "#(manualCollateralsJson)",
      "selectedCollaterals": "#(td.selectedCollaterals)",
      "collateralAssignmentDetails": "#(td.collateralAssignmentDetails)",
      "commitmentId": "#(td.commitmentId)",
      "settlementMode": "#(td.settlementMode)",
      "paymentType": "#(td.paymentType)",
      "repaymentAccountNumber": "#(td.repaymentAccountNumber)",
      "feeAccountNumber": "#(td.feeAccountNumber)",
      "feeFundingAccountNumber": "#(td.feeFundingAccountNumber)",
      "disbursementMode": "#(td.disbursementMode)",
      "disbursementDate": "#(td.disbursementDate)",
      "disbursementAccountNumber": "#(td.disbursementAccountNumber)",
      "disbursementNotes": "#(td.disbursementNotes)",
      "docSignedState": "#(td.docSignedState)",
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
    Then status 200
    * match response.loanAmount == td.loanAmount
    * match response.selectedProductCode == td.selectedProductCode
    # The server renumbers the application once the product type is saved (LOAN--<user>-n -> LOAN-<type>-<user>-n),
    # as 04 Step 09 handles: later calls by reference (document upload) must use the new number.
    * def draftRef = response.applicationRef != null ? response.applicationRef : draftRef
    * print '✔ [SB-ORIG] Step 09: Draft saved — amount', response.loanAmount, '| product', response.selectedProductCode

    # Step 10: Document checklist + upload
    Given path '/v1/product-config/checklist'
    And param productTypeCode = td.loanProductType
    And param productCode = td.selectedProductCode
    When method GET
    Then match [200, 404] contains responseStatus
    * def isUploadDoc = td.uploadDocument == 'true' || td.uploadDocument === true || td.uploadDocument == 'Y'
    # uploadDocumentName may name several documents separated by ';' - one upload each, under the
    # name the sheet gives. uploadDocumentType is one type for all of them or a ';' list in the same order.
    * def docUploads =
    """
    function() {
      var names = sheetText(td.uploadDocumentName) == null ? [] : sheetText(td.uploadDocumentName).split(';');
      var types = sheetText(td.uploadDocumentType) == null ? [] : sheetText(td.uploadDocumentType).split(';');
      var out = [];
      for (var i = 0; i < names.length; i++) {
        if (names[i].trim() == '') continue;
        var type = types.length > i ? types[i].trim() : (types.length > 0 ? types[0].trim() : null);
        out.push({ appRef: draftRef, docType: type, docName: names[i].trim(), docStatus: sheetText(td.documentStatus), docComment: sheetText(td.documentStatusComment), docPhase: sheetText(td.uploadDocumentPhase), authHeader: officerAuthHeader, baseUrl: baseUrl });
      }
      return out;
    }
    """
    * def docsToUpload = isUploadDoc ? docUploads() : []
    * if (karate.sizeOf(docsToUpload) > 0) karate.call('classpath:features/loans/upload-document-helper.feature', docsToUpload)

    # Step 11: Charges + submit
    # The officer collects the APPLICATION charges (applicationCharges). The draft is normally linked to its
    # application already; when it is not, submit answers 409 for a due charge and they are collected then.
    * def stageCharges = read('classpath:features/loans/stage-charges.js')
    * def draftAppId = function() { var d = karate.http(baseUrl + '/v1/origination/draft/' + draftId).header('Authorization', officerAuthHeader).get().body; return d == null ? null : d.linkedApplicationId }
    * def preSubmitAppId = draftAppId()
    * def appCharges = preSubmitAppId ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', preSubmitAppId, td, feeAcct) : null
    * if (appCharges != null && appCharges.error) karate.fail('[charges APPLICATION] TestCase ' + td.testCaseId + ': ' + appCharges.error)
    Given path '/v1/origination/draft/' + draftId + '/submit'
    When method POST
    * def submitStatus = responseStatus
    * def submitResponse = response
    # Say what the submit API objected to, in its own words.
    * if (submitStatus >= 400 && submitStatus != 409) karate.fail('[SUBMIT REFUSED] TestCase ' + td.testCaseId + ': HTTP ' + submitStatus + ' ' + karate.toString(submitResponse))
    * def appCharges = (submitStatus == 409) ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', draftAppId(), td, feeAcct) : appCharges
    * if (appCharges != null && appCharges.error) karate.fail('[charges APPLICATION] TestCase ' + td.testCaseId + ': ' + appCharges.error)
    * def resubmitResult = (submitStatus == 409) ? karate.call('classpath:features/loans/resubmit-draft-helper.feature', { draftId: draftId, authHeader: officerAuthHeader, baseUrl: baseUrl }) : null
    * def finalSubmitResponse = (resubmitResult && resubmitResult.resubmittedResponse) ? resubmitResult.resubmittedResponse : submitResponse
    * def appId = finalSubmitResponse.linkedApplicationId
    * match appId == '#notnull'
    * def appCharges = appCharges == null ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', appId, td, feeAcct) : appCharges
    * if (appCharges != null && appCharges.error) karate.fail('[charges APPLICATION] TestCase ' + td.testCaseId + ': ' + appCharges.error)
    * print '✔ [SB-ORIG] Application charges -> collected', appCharges.collected, '| waived', appCharges.waived

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * match response.status == 'SUBMITTED'
    * print '✔ [SB-ORIG] Step 11: Submitted — appId', appId, '| status SUBMITTED'

  # ═══════════════════════════════════════════════════════════════════════════
  # @resubmit — officer picks up a PENDING_DOCUMENTS application and resubmits it
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @resubmit
  Scenario: Officer claims, recalls to draft, uploads the requested document, amends and resubmits
    * url baseUrl
    * configure headers = function(){ return { Authorization: officerAuthHeader, 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }
    * def authHeader = officerAuthHeader
    * def val = function(v) { return (v == null || (typeof v === 'string' && v.trim() == '')) ? null : (typeof v === 'string' ? v.trim() : v) }

    # 1. Claim (PENDING_DOCUMENTS sits in the officer pool; recall requires the claim)
    * karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: officerAuthHeader, baseUrl: baseUrl })
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [SB-RESUBMIT] 1. Officer claim -> assignedTo:', response.assignedTo, '| status:', response.status

    # 2. Recall to draft (workflow cancelled, application IN_PROGRESS, draft at step 3)
    * def recallRes = karate.call('classpath:features/loans/recall-to-draft-helper.feature', { appId: appId, authHeader: officerAuthHeader, baseUrl: baseUrl })
    * def recalledDraftId = recallRes.recalledDraftId
    * print '✔ [SB-RESUBMIT] 2. Recalled to draft', recalledDraftId, '| step', recallRes.recalledCurrentStep

    # 3. Upload the requested document (by application ref, ORIGINATION phase)
    * def rDocType = val(td.resubmitDocumentType)
    * def rDocName = val(td.resubmitDocumentName)
    * def rDocStatus = val(td.resubmitDocumentStatus)
    * def rDocComment = val(td.resubmitDocumentComment)
    * if (rDocType != null) karate.call('classpath:features/loans/upload-document-helper.feature', { appRef: draftRef, docType: rDocType, docName: rDocName, docStatus: rDocStatus, docComment: rDocComment, docPhase: val(td.uploadDocumentPhase), authHeader: officerAuthHeader, baseUrl: baseUrl })
    * print '✔ [SB-RESUBMIT] 3. Document:', (rDocType != null ? (rDocType + ' / ' + rDocName) : 'none requested')

    # 4. Amend facility details ON TOP OF the server's current draft. Only the amend* columns are
    #    overridden; everything else is sent back exactly as the wizard holds it, so a manually resumed
    #    application (whose row has no origination columns) is not blanked out. The server locks
    #    loanAmount and loanTerm/termFrequency after a send-back (409 "... cannot be changed after the
    #    application has been returned by the underwriter").
    Given path '/v1/origination/draft/' + recalledDraftId
    When method GET
    Then status 200
    * def draftNow = response
    * def newTerm  = (val(td.amendLoanTerm) != null) ? td.amendLoanTerm : draftNow.loanTerm
    * def newTf    = (val(td.amendTermFrequency) != null) ? td.amendTermFrequency : draftNow.termFrequency
    * def newRf    = (val(td.amendRepaymentFrequency) != null) ? td.amendRepaymentFrequency : draftNow.repaymentFrequency
    * def newRate  = (val(td.amendInterestRate) != null) ? td.amendInterestRate : (draftNow.overriddenInterestRate != null ? draftNow.overriddenInterestRate : td.overriddenInterestRate)
    * def newNotes = (val(td.amendDisbursementNotes) != null) ? td.amendDisbursementNotes : (draftNow.disbursementNotes != null ? draftNow.disbursementNotes : td.disbursementNotes)
    * def overrides = { id: '#(recalledDraftId)', applicationRef: '#(draftRef)' }
    * if (val(td.amendLoanTerm) != null) karate.set('overrides', '$.loanTerm', td.amendLoanTerm)
    * if (val(td.amendTermFrequency) != null) karate.set('overrides', '$.termFrequency', td.amendTermFrequency)
    * if (val(td.amendRepaymentFrequency) != null) karate.set('overrides', '$.repaymentFrequency', td.amendRepaymentFrequency)
    * if (val(td.amendInterestRate) != null) karate.set('overrides', '$.overriddenInterestRate', td.amendInterestRate)
    * if (val(td.amendDisbursementNotes) != null) karate.set('overrides', '$.disbursementNotes', td.amendDisbursementNotes)
    * def amendBody = karate.merge(draftNow, overrides)
    * if (newTerm != draftNow.loanTerm || newTf != draftNow.termFrequency) karate.log('[SB-RESUBMIT] WARNING: amendLoanTerm/amendTermFrequency set - the server locks tenure after a send-back and will answer 409')
    Given path '/v1/origination/draft'
    And request amendBody
    When method PUT
    * if (responseStatus != 200) karate.fail('[SB-RESUBMIT] amend PUT /v1/origination/draft -> HTTP ' + responseStatus + ': ' + (response && response.detail ? response.detail : karate.pretty(response)))
    * print '✔ [SB-RESUBMIT] 4. Amended -> term', response.loanTerm, response.termFrequency, '| repay', response.repaymentFrequency, '| rate', newRate, '| notes:', newNotes

    # 5. Charges + submit (same 409 fallback as origination)
    * def stageCharges = read('classpath:features/loans/stage-charges.js')
    * def appCharges = stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', appId, td, feeAcct)
    * if (appCharges != null && appCharges.error) karate.fail('[charges APPLICATION] TestCase ' + td.testCaseId + ': ' + appCharges.error)
    Given path '/v1/origination/draft/' + recalledDraftId + '/submit'
    When method POST
    * def submitStatus = responseStatus
    * def appCharges = (submitStatus == 409) ? stageCharges(officerAuthHeader, 'APPLICATION', 'applicationCharges', appId, td, feeAcct) : appCharges
    * if (appCharges != null && appCharges.error) karate.fail('[charges APPLICATION] TestCase ' + td.testCaseId + ': ' + appCharges.error)
    * def resubmitResult = (submitStatus == 409) ? karate.call('classpath:features/loans/resubmit-draft-helper.feature', { draftId: recalledDraftId, authHeader: officerAuthHeader, baseUrl: baseUrl }) : null
    * if (submitStatus != 200 && submitStatus != 409) karate.fail('[SB-RESUBMIT] draft submit returned HTTP ' + submitStatus + ': ' + karate.pretty(response))
    * def linked = (resubmitResult && resubmitResult.resubmittedResponse) ? resubmitResult.resubmittedResponse.linkedApplicationId : response.linkedApplicationId
    * if (linked != null && linked != appId) karate.fail('[SB-RESUBMIT] resubmit created a DIFFERENT application ' + linked + ' instead of reusing ' + appId + ' — recall did not put the application in IN_PROGRESS')

    # 6. The workflow restarts at intake; the application leaves IN_PROGRESS / PENDING_DOCUMENTS
    Given path '/v1/loans/' + appId
    And retry until response.status != 'IN_PROGRESS' && response.status != 'PENDING_DOCUMENTS'
    When method GET
    Then status 200
    * print '✔ [SB-RESUBMIT] 5. Resubmitted — application', appId, 'now', response.status

    # Effective row values after the amendment, handed back so later phases and later rows use them
    * def tdOut = karate.merge(td, { loanTerm: newTerm, termFrequency: newTf, repaymentFrequency: newRf, overriddenInterestRate: newRate, disbursementNotes: newNotes })

  # ═══════════════════════════════════════════════════════════════════════════
  # @underwriter — 04 Steps 13-15 plus the send-back / reject expectations
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @underwriter
  Scenario: Underwriter claims, completes intake, evaluates, settles charges and acts
    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }
    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn
    * def val = function(v) { return (v == null || (typeof v === 'string' && v.trim() == '')) ? null : (typeof v === 'string' ? v.trim() : v) }
    * def activeUwUser = (val(td.underwriterUsername) != null) ? td.underwriterUsername.toString().trim() : defaultUnderwriterUsername
    * def activeUwPass = defaultUnderwriterPassword
    * def uwToken = login(activeUwUser, activeUwPass)
    * def uwAuthHeader = 'Bearer ' + uwToken
    * def authHeader = uwAuthHeader

    # Step 13: claim + intake
    * karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * print '✔ [SB-UW] Claim ->', activeUwUser, '| assignedTo:', response.assignedTo, '| status:', response.status

    Given path '/v1/loans/' + appId + '/tasks'
    And retry until response.length > 0
    When method GET
    Then status 200
    * def intakeTasks = karate.jsonPath(response, "$.[?(@.taskDefinitionKey=='applicationIntake' || @.taskDefinitionKey=='corporateIntake')]")
    * def intakeBody = (intakeTasks.length > 0 && intakeTasks[0].taskDefinitionKey == 'corporateIntake') ? { promoters: [td.promoterName] } : {}
    * if (intakeTasks.length > 0) karate.call('classpath:features/loans/complete-task-helper.feature', { taskId: intakeTasks[0].id, requestBody: intakeBody, authHeader: uwAuthHeader, baseUrl: baseUrl })
    * print '✔ [SB-UW] Intake tasks completed:', intakeTasks.length

    # Step 14: wait for Underwriter Review, open the assessment, claim
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until karate.jsonPath(response, "$.[?(@.name=='Underwriter Review' || @.taskDefinitionKey=='underwriterReview')]").length > 0
    When method GET
    Then status 200

    # Step 14b: the underwriter opens the assessment. The server resolves the method and scorecard (the
    # sub-product's own, else the product type's) and, for AUTO, lets the scorecard decide at once (as 04):
    #   AUTO_APPROVED   no underwriter decision exists - only uwAction APPROVE_TO_APPROVER is accepted, and skipped
    #   AUTO_REJECTED   the application is rejected - the row fails
    #   AUTO / EXTERNAL / MANUAL_EXTERNAL with no scorecard result yet: evaluate it so the underwriter can decide
    * def assessRes = karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', uwAuthHeader).get()
    * if (assessRes.status >= 400) karate.fail('[SB-UW] TestCase ' + td.testCaseId + ': opening the assessment failed with HTTP ' + assessRes.status + ' ' + karate.toString(assessRes.body))
    * def assessRec = assessRes.body.data ? assessRes.body.data : assessRes.body
    * def assessMethod = assessRec.resolvedAssessmentMethod
    * def autoApproved = assessRec.uwDecision == 'AUTO_APPROVED'
    * if (assessRec.uwDecision == 'AUTO_REJECTED') karate.fail('[SB-UW] TestCase ' + td.testCaseId + ': AUTO-REJECTED by the scorecard (' + assessRec.scorecardResult + ', ' + assessRec.scorecardTotalScorePct + '%): ' + assessRec.declineReason)
    * if (autoApproved && uwAction != 'APPROVE_TO_APPROVER') karate.fail('[SB-UW] TestCase ' + td.testCaseId + ': the server AUTO-APPROVED application ' + appId + ' at assessment (method ' + assessMethod + '), so uwAction ' + uwAction + ' cannot be taken - use a product whose assessment method is MANUAL for underwriter decisions')
    * def needsScorecard = !autoApproved && (assessMethod == 'AUTO' || assessMethod == 'EXTERNAL' || assessMethod == 'MANUAL_EXTERNAL') && assessRec.scorecardResult == null
    * def scorecardEvalStatus = needsScorecard ? karate.http(baseUrl + '/v1/assessment/' + appId + '/evaluate-scorecard').header('Authorization', uwAuthHeader).header('Content-Type', 'application/json').post({}).status : 'NOT NEEDED'
    * print '✔ [SB-UW] Assessment opened -> method', assessMethod, '| scorecard', assessRec.scorecardResult, assessRec.scorecardTotalScorePct, '| decision', assessRec.uwDecision, '| evaluation', scorecardEvalStatus
    * if (autoApproved) karate.log('[SB-UW] application', appId, 'AUTO-APPROVED by the scorecard - no underwriter decision to take')

    * if (!autoApproved) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })
    * if (!autoApproved) karate.call('classpath:features/loans/assessment-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl })

    # ASSESSMENT charges (assessmentCharges), collected by the underwriter in its own session - also when the
    # scorecard AUTO-approved, since no other stage collects them then.
    * def stageCharges = read('classpath:features/loans/stage-charges.js')
    * def uwCharges = stageCharges(uwAuthHeader, 'ASSESSMENT', 'assessmentCharges', appId, td, feeAcct)
    * if (uwCharges != null && uwCharges.error) karate.fail('[charges ASSESSMENT] TestCase ' + td.testCaseId + ': ' + uwCharges.error)
    * print '✔ [SB-UW] Assessment charges -> collected', uwCharges.collected, '| waived', uwCharges.waived

    # Underwriter action from the row
    * def isSendBack = (uwAction == 'REQUEST_ADDITIONAL_DOCS' || uwAction == 'RETURN_FOR_DOCS')
    * def resolvedUwAction = uwAction
    * def uwComment = val(td.uwComment)
    * def docsList = (val(td.uwRequestedDocs) != null) ? td.uwRequestedDocs.toString().split(',').map(function(s){ return s.trim() }).filter(function(s){ return s != '' }) : []
    * def notifyOff = td.notifyOfficer == 'true' || td.notifyOfficer === true || td.notifyOfficer == 'Y'
    * def notifyCust = td.notifyCustomer == 'true' || td.notifyCustomer === true || td.notifyCustomer == 'Y'
    * def uwPayload = { action: '#(resolvedUwAction)', comment: '#(uwComment)', requestedDocuments: '#(docsList)', notifyOfficer: '#(notifyOff)', notifyCustomer: '#(notifyCust)' }
    * if (resolvedUwAction == 'REJECT') karate.set('uwPayload', '$.rejectReason', val(td.rejectReason))
    * if (!autoApproved) karate.call('classpath:features/loans/uw-action-helper.feature', { appId: appId, authHeader: uwAuthHeader, baseUrl: baseUrl, requestBody: uwPayload })

    # Step 15: what the action must have done
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def postUwStatus = response.status
    * expect(autoApproved, postUwStatus, 'APPROVED', 'status after AUTO approval')
    * expect(isSendBack, postUwStatus, 'PENDING_DOCUMENTS', 'status after UW send-back')
    * expect(resolvedUwAction == 'REJECT', postUwStatus, 'REJECTED', 'status after UW reject')
    * expect(resolvedUwAction == 'REJECT', response.assignedTo, '##null', 'claim released after reject')
    * print '✔ [SB-UW] Action', resolvedUwAction, '->', postUwStatus, '| phase:', response.currentPhaseId, (isSendBack ? '| sent back to application phase, docs requested: ' + docsList : '')
    * karate.call('classpath:features/auth/logout-helper.feature', { authHeader: uwAuthHeader })

  # ═══════════════════════════════════════════════════════════════════════════
  # @approver — 04 Step 16 with role selection, prior votes, send-back / decline expectations
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @approver
  Scenario: Approver(s) claim and vote / send back / decline
    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }
    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn
    * def val = function(v) { return (v == null || (typeof v === 'string' && v.trim() == '')) ? null : (typeof v === 'string' ? v.trim() : v) }
    * def activeApprover1User = val(td.approver1Username)
    * def activeApprover2User = val(td.approver2Username)
    * def activeCcUser = (val(td.ccUsername) != null) ? val(td.ccUsername) : defaultApprover3Username
    * def activeCcPass = defaultApprover3Password

    # Wait for the Credit Approval step, then resolve which seeded approver the limit points at (as 04 does)
    Given path '/v1/loans/' + appId + '/tasks'
    And retry until karate.jsonPath(response, "$.[?(@.name=='Credit Approval' || @.taskDefinitionKey=='creditApproval')]").length > 0
    When method GET
    Then status 200

    Given path '/v1/assessment/' + appId
    When method GET
    Then status 200
    * def targetAuthType = response.directResolvedAuthorityType
    * def targetAuthNames = response.directResolvedAuthorityNames
    * def firstApproverUser  = (activeApprover1User != null) ? activeApprover1User : ((targetAuthType == 'USER' && targetAuthNames == defaultApprover2Username) ? defaultApprover2Username : defaultApprover1Username)
    * def firstApproverPass  = (activeApprover1User != null) ? defaultApprover1Password : ((targetAuthType == 'USER' && targetAuthNames == defaultApprover2Username) ? defaultApprover2Password : defaultApprover1Password)
    * def secondApproverUser = (activeApprover2User != null) ? activeApprover2User : ((firstApproverUser == defaultApprover1Username) ? defaultApprover2Username : defaultApprover1Username)
    * def secondApproverPass = (activeApprover2User != null) ? defaultApprover2Password : ((firstApproverUser == defaultApprover1Username) ? defaultApprover2Password : defaultApprover1Password)

    # approverRole CHAIN = whoever the SEQUENTIAL chain names as the current authority: a USER hop signs in as that
    # user (seeded accounts share the environment password), a ROLE / CREDIT_COMMITTEE hop as approver 1.
    * def chainState = function() { var a = karate.http(baseUrl + '/v1/assessment/' + appId).header('Authorization', authHeader).get().body; a = (a != null && a.data) ? a.data : a; return a == null ? null : a.sequentialChainState }
    * def chainUser = function() { var c = chainState(); if (c == null || c.sequentialRouting != true) karate.fail('[SB-APPROVER] approverRole CHAIN needs SEQUENTIAL routing - application ' + appId + ' has none'); karate.log('[SB-APPROVER] chain hop', c.currentHopIndex + 1, '/', c.totalHops, '->', c.currentAuthorityType, c.currentAuthorityName, '(limit ' + c.currentLimitAmount + ')'); return c.currentAuthorityType == 'USER' ? { user: c.currentAuthorityName, pass: defaultApprover1Password } : { user: firstApproverUser, pass: firstApproverPass } }
    * def credsFor = function(role) { var r = (role || 'APPROVER1').toString().toUpperCase(); if (r == 'CHAIN') return chainUser(); if (r == 'APPROVER2') return { user: secondApproverUser, pass: secondApproverPass }; if (r == 'CC_USER' || r == 'CC') return { user: activeCcUser, pass: activeCcPass }; return { user: firstApproverUser, pass: firstApproverPass }; }
    * def notifyOff = td.notifyOfficer == 'true' || td.notifyOfficer === true || td.notifyOfficer == 'Y'
    * def notifyCust = td.notifyCustomer == 'true' || td.notifyCustomer === true || td.notifyCustomer == 'Y'
    * def sessions = []
    * def castVote =
    """
    function(role, action, comment) {
      var c = credsFor(role);
      var hdr = 'Bearer ' + login(c.user, c.pass);
      sessions.push(hdr);
      karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: hdr, baseUrl: baseUrl });
      var payload = { action: action, comment: comment, notifyOfficer: notifyOff, notifyCustomer: notifyCust };
      if (td.overriddenInterestRate != null && Number(td.overriddenInterestRate) > 0) payload.overriddenInterestRate = td.overriddenInterestRate;
      if (action == 'DECLINE') payload.declineReason = val(td.rejectReason);
      if (action == 'REFER') payload.referComment = comment;
      karate.call('classpath:features/loans/approver-action-helper.feature', { appId: appId, authHeader: hdr, baseUrl: baseUrl, requestBody: payload });
      var r = karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', hdr).get();
      karate.log('[SB-APPROVER]', role, '(' + c.user + ')', action, '->', r.body.status);
      return r.body.status;
    }
    """

    # Prior votes, e.g. "APPROVER1:APPROVE;APPROVER2:APPROVE" — cast before the row's main action
    * def priorSpec = val(td.approverPriorVotes)
    * def priorVotes = (priorSpec != null) ? priorSpec.toString().split(';').map(function(s){ return s.trim() }).filter(function(s){ return s != '' }) : []
    * def castPrior = function(spec) { var p = spec.split(':'); castVote(p[0].trim(), p[1].trim().toUpperCase(), val(td.approverComment)) }
    * karate.forEach(priorVotes, castPrior)

    # Main action by the row's approverRole
    * def mainRole = val(td.approverRole).toString().toUpperCase()
    * def mainComment = val(td.approverComment)
    * def hopBefore = approverAction == 'REFER' ? chainState() : null
    * def statusAfterMain = castVote(mainRole, approverAction, mainComment)

    # APPROVE may need a quorum vote from the other approver (as 04 Step 16c)
    * def otherRole = (mainRole == 'CHAIN') ? 'CHAIN' : ((mainRole == 'APPROVER2') ? 'APPROVER1' : 'APPROVER2')
    * def statusAfterQuorum = (approverAction == 'APPROVE' && statusAfterMain != 'APPROVED') ? castVote(otherRole, approverAction, mainComment) : statusAfterMain

    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * def postApproverStatus = response.status
    * expect(approverAction == 'REQUEST_DOCS', postApproverStatus, 'PENDING_DOCUMENTS', 'status after approver send-back')
    * expect(approverAction == 'RETURN', postApproverStatus, 'UNDER_REVIEW', 'status after approver return to underwriter')
    # REFER (SEQUENTIAL chains only) passes the application to the next hop: still UNDER_REVIEW, claim released
    * def hopAfter = approverAction == 'REFER' ? chainState() : null
    * expect(approverAction == 'REFER', postApproverStatus, 'UNDER_REVIEW', 'status after approver refer')
    * expect(approverAction == 'REFER', (hopAfter != null ? hopAfter.currentHopIndex : null), (hopBefore != null ? hopBefore.currentHopIndex + 1 : null), 'chain hop after refer')
    * if (approverAction == 'REFER') karate.log('✔ [SB-APPROVER] REFER moved the chain from hop', hopBefore.currentHopIndex + 1, '(' + hopBefore.currentAuthorityName + ') to hop', hopAfter.currentHopIndex + 1, '(' + hopAfter.currentAuthorityType + ' ' + hopAfter.currentAuthorityName + ')')
    * expect(approverAction == 'RETURN', response.currentPhaseStatusId, 'UNDERWRITER_APPROVE', 'phase after approver return to underwriter')
    * expect(approverAction == 'RETURN', response.assignedTo, '##null', 'claim released after approver return to underwriter')
    * expect(approverAction == 'DECLINE', postApproverStatus, 'REJECTED', 'status after approver decline')
    * expect(approverAction == 'APPROVE', postApproverStatus, 'APPROVED', 'status after approver approve')
    * print '✔ [SB-APPROVER]', mainRole, approverAction, '->', postApproverStatus, '| phase:', response.currentPhaseId
    * def logoutAll = function(hdr) { karate.call('classpath:features/auth/logout-helper.feature', { authHeader: hdr }) }
    * karate.forEach(sessions, logoutAll)

  # ═══════════════════════════════════════════════════════════════════════════
  # @postApproval — 04 Steps 17-19: offer issue, offer accept, loan setup + CBS
  # ═══════════════════════════════════════════════════════════════════════════
  @ignore @postApproval
  Scenario: Issue offer, accept offer, set up loan and disburse
    * url baseUrl
    * configure headers = function(){ return { Authorization: (typeof authHeader !== 'undefined' ? authHeader : ''), 'Content-Type': 'application/json' } }
    * configure retry = { count: 45, interval: 2000 }
    * def expect = function(cond, actual, expected, label) { if (!cond) return; var m = karate.match(actual, expected); if (!m.pass) karate.fail('[' + label + '] ' + m.message) }
    * def loginFn = (typeof login !== 'undefined' && login != null) ? login : function(u, p) { return karate.call('classpath:features/auth/auth.feature', { username: u, password: p }).token }
    * def login = loginFn
    * def val = function(v) { return (v == null || (typeof v === 'string' && v.trim() == '')) ? null : (typeof v === 'string' ? v.trim() : v) }
    * def flag = function(v) { var s = val(v); return s === true || (s != null && ['Y','YES','TRUE'].indexOf(s.toString().toUpperCase()) >= 0) }
    # Phase actions from the sheet, each required when its stage runs:
    #   issuerAction ISSUE | CANCEL (the issuer cancels the application instead of issuing)
    #   acceptorAction ACCEPT | DECLINE (records the customer's decline)   setupAction CREATE_ACCOUNT
    * def need = function(col, allowed) { var v = val(td[col]); if (v == null) throw new Error('[sheet] ' + col + ' is blank for ' + td.testCaseId + ' - that stage runs, so fill it'); v = v.toString().toUpperCase(); if (allowed.indexOf(v) < 0) throw new Error('[sheet] ' + col + ' "' + v + '" on ' + td.testCaseId + ' is not supported - use ' + allowed.join(' or ')); return v }
    * def issuerAction = flag(td.skipIssueOffer) ? null : need('issuerAction', ['ISSUE', 'CANCEL'])
    * def isCancelAtIssue = issuerAction == 'CANCEL'
    * def acceptorAction = (flag(td.skipOfferAccept) || isCancelAtIssue) ? null : need('acceptorAction', ['ACCEPT', 'DECLINE'])
    * def isDeclineOffer = acceptorAction == 'DECLINE'
    * def setupAction = (flag(td.skipLoanSetup) || isCancelAtIssue || isDeclineOffer) ? null : need('setupAction', ['CREATE_ACCOUNT'])
    * def rejectReason = val(td.rejectReason)
    * def isSkipIssueOffer = flag(td.skipIssueOffer) || isCancelAtIssue
    * def isSkipOfferAccept = flag(td.skipOfferAccept) || isCancelAtIssue || isDeclineOffer
    * def isSkipSetup = flag(td.skipLoanSetup) || isCancelAtIssue || isDeclineOffer
    * def activeIssuerUser = (val(td.issuerUsername) != null) ? val(td.issuerUsername) : defaultIssuerUsername
    * def activeAcceptorUser = (val(td.acceptorUsername) != null) ? val(td.acceptorUsername) : defaultAcceptorUsername
    * def activeSetupUser = (val(td.setupUsername) != null) ? val(td.setupUsername) : defaultSetupUsername

    * def stageCharges = read('classpath:features/loans/stage-charges.js')

    # Step 17-: rejectAtOfferIssue — the issuer claims and CANCELS the application instead of issuing
    * def cancelHeader = isCancelAtIssue ? ('Bearer ' + login(activeIssuerUser, defaultIssuerPassword)) : null
    * if (isCancelAtIssue) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: cancelHeader, baseUrl: baseUrl })
    * def cancelRes = isCancelAtIssue ? karate.http(baseUrl + '/v1/loans/' + appId + '/cancel').param('reason', rejectReason).header('Authorization', cancelHeader).header('Content-Type', 'application/json').post({}) : null
    * def cancelledBy = isCancelAtIssue ? activeIssuerUser : null
    # CANCEL_APPLICATION is seeded to MANAGER / ADMIN only (V2042); other roles get it per deployment. When the
    # issuer is refused (HTTP 403) the admin cancels instead - admins bypass the claim-ownership check.
    * def adminCancelHeader = (cancelRes != null && cancelRes.status == 403) ? ('Bearer ' + login(activeAdminUser, activeAdminPass)) : null
    * if (adminCancelHeader != null) karate.log('[SB-POST] issuer', activeIssuerUser, 'may not cancel applications on this server (HTTP 403) - cancelling as admin', activeAdminUser)
    * def cancelRes = (adminCancelHeader != null) ? karate.http(baseUrl + '/v1/loans/' + appId + '/cancel').param('reason', rejectReason).header('Authorization', adminCancelHeader).header('Content-Type', 'application/json').post({}) : cancelRes
    * def cancelledBy = (adminCancelHeader != null) ? activeAdminUser : cancelledBy
    * if (cancelRes != null && cancelRes.status != 200) karate.fail('[SB-POST] cancel at offer issue returned HTTP ' + cancelRes.status + ': ' + karate.pretty(cancelRes.body))
    * expect(isCancelAtIssue, (cancelRes != null ? cancelRes.body.status : null), 'CANCELLED', 'status after cancel at offer issue')
    * if (isCancelAtIssue) karate.log('✔ [SB-POST] Step 17-: application', appId, 'CANCELLED at offer issue by', cancelledBy, '| reason:', rejectReason)
    * if (cancelHeader != null) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: cancelHeader })
    * if (adminCancelHeader != null) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: adminCancelHeader })

    # Step 17: Offer issue
    * def issuerAuthHeader = isSkipIssueOffer ? null : ('Bearer ' + login(activeIssuerUser, defaultIssuerPassword))
    * def authHeader = issuerAuthHeader
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl })
    * def issueCharges = isSkipIssueOffer ? null : stageCharges(issuerAuthHeader, 'OFFER', 'offerCharges', appId, td, feeAcct)
    * if (issueCharges != null && issueCharges.error) karate.fail('[charges OFFER] TestCase ' + td.testCaseId + ': ' + issueCharges.error)
    * def issuePayload = { rateAdjustment: '#(td.offerRateAdjustment)', principalReduction: '#(td.offerPrincipalReduction)', offerValidityDate: '#(td.offerValidityDate)' }
    * if (!isSkipIssueOffer) karate.call('classpath:features/loans/offer-issue-helper.feature', { appId: appId, authHeader: issuerAuthHeader, baseUrl: baseUrl, requestBody: issuePayload })
    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || isSkipIssueOffer
    * expect(!isSkipIssueOffer, response.status, '#regex ISSUED|OFFER_ISSUED', 'offer status after issue')
    * print '✔ [SB-POST] Step 17: Offer', (isSkipIssueOffer ? 'skipped' : ('issued -> ' + (response.offerNumber ? response.offerNumber : (response.offerReference ? response.offerReference : response.id)) + ' | ' + response.status))

    # Step 17b: rejectAtOfferAcceptance — the acceptor claims and records the customer's DECLINE
    * def declineHeader = isDeclineOffer ? ('Bearer ' + login(activeAcceptorUser, defaultAcceptorPassword)) : null
    * if (isDeclineOffer) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: declineHeader, baseUrl: baseUrl })
    * def declineRes = isDeclineOffer ? karate.http(baseUrl + '/v1/offer/' + appId + '/decline').header('Authorization', declineHeader).header('Content-Type', 'application/json').post({ declinedReason: rejectReason }) : null
    * if (declineRes != null && declineRes.status != 200) karate.fail('[SB-POST] offer decline returned HTTP ' + declineRes.status + ': ' + karate.pretty(declineRes.body))
    * def declinedApp = isDeclineOffer ? karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', declineHeader).get().body : null
    * expect(isDeclineOffer, (declinedApp != null ? declinedApp.status : null), 'OFFER_DECLINED', 'status after offer decline')
    * if (isDeclineOffer) karate.log('✔ [SB-POST] Step 17b: offer DECLINED by', activeAcceptorUser, '| offer status:', declineRes.body.offerStatus, '| application:', declinedApp.status, '| reason:', rejectReason)
    * if (declineHeader != null) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: declineHeader })

    # Step 17c: Offer accept
    * def acceptorAuthHeader = isSkipOfferAccept ? null : ('Bearer ' + login(activeAcceptorUser, defaultAcceptorPassword))
    * def authHeader = acceptorAuthHeader
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl })
    * def acceptCharges = isSkipOfferAccept ? null : stageCharges(acceptorAuthHeader, 'OFFER_ACCEPTANCE', 'offerAcceptanceCharges', appId, td, feeAcct)
    * if (acceptCharges != null && acceptCharges.error) karate.fail('[charges OFFER_ACCEPTANCE] TestCase ' + td.testCaseId + ': ' + acceptCharges.error)
    * if (!isSkipOfferAccept) karate.call('classpath:features/loans/offer-accept-helper.feature', { appId: appId, authHeader: acceptorAuthHeader, baseUrl: baseUrl, requestBody: {} })
    Given path '/v1/offer/' + appId
    When method GET
    Then assert responseStatus == 200 || isSkipOfferAccept
    * expect(!isSkipOfferAccept, response.status, '#regex ACCEPTED|OFFER_ACCEPTED', 'offer status after accept')
    * print '✔ [SB-POST] Step 17c: Offer', (isSkipOfferAccept ? 'acceptance skipped' : ('accepted -> ' + response.status))

    # Step 18: Loan setup — the schedule check uses the EFFECTIVE tenure (after any amendment)
    # A loan (retail or enterprise) gets its account from CBS create-account; an OVERDRAFT (originateFeature OVERDRAFT /
    # ENTERPRISE_OD) is set up without a schedule - an OD account with its limit and debit rate.
    * def isOd = val(td.originateFeature) != null && ['OVERDRAFT', 'ENTERPRISE_OD'].indexOf(('' + val(td.originateFeature)).toUpperCase()) >= 0
    * def setupAuthHeader = isSkipSetup ? null : ('Bearer ' + login(activeSetupUser, defaultSetupPassword))
    # Read-only steps below need SOME session when setup is skipped (skipLoanSetup, cancel, offer decline): fall back to the row's officer session
    * def authHeader = (setupAuthHeader != null) ? setupAuthHeader : ((acceptorAuthHeader != null) ? acceptorAuthHeader : ((issuerAuthHeader != null) ? issuerAuthHeader : officerAuthHeader))
    * if (!isSkipSetup) karate.call('classpath:features/loans/claim-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl })
    Given path '/v1/loans/' + appId
    When method GET
    Then status 200
    * match response.loanAmount == td.loanAmount
    * match response.customerId == td.customerId
    * print '✔ [SB-POST] Step 18a: Setup claim -> amount', response.loanAmount, '| term', response.loanTerm, response.termFrequency, '| expected term', td.loanTerm, td.termFrequency

    * def calcTermMonths = (td.termFrequency == 'YEARS' ? td.loanTerm * 12 : td.loanTerm)
    * def validateRes = isSkipSetup ? null : karate.http(baseUrl + '/v1/loan-setup/' + appId + '/validate-account?accountNumber=' + feeAcct).header('Authorization', setupAuthHeader).get()
    * if (validateRes != null && validateRes.status != 200) karate.fail('[SB-POST] validate-account returned HTTP ' + validateRes.status)
    # The product as LO holds it (manual-schedule products send their auto population, as in 04).
    * def searchRes = (isSkipSetup || isOd) ? null : karate.http(baseUrl + '/v1/origination/products/search?currency=' + td.loanAmountCurrency + '&size=200').header('Authorization', setupAuthHeader).get()
    * def searchItems = (searchRes != null && searchRes.status == 200 && searchRes.body.items) ? searchRes.body.items : []
    * def cbsProduct = karate.filter(searchItems, function(p){ return p.productCode == td.selectedProductCode })
    * def cbsProduct = cbsProduct.length > 0 ? cbsProduct[0] : {}
    * def isManualProduct = cbsProduct.repaymentTypeDesc == 'Manual Schedule'
    * def schedFirstRepay = td.repaymentStartDate ? ('' + td.repaymentStartDate).substring(0, 10) : null
    # Regenerate request with the fields the UI's Loan Setup screen sends (RegenerateScheduleRequest, as 04 Step 18b).
    # Other names are ignored by the server, which then cannot call CBS and silently returns its LOCAL fallback.
    * def regenReq = { principal: '#(td.loanAmount)', ratePercent: '#(td.overriddenInterestRate)', tenureMonths: '#(calcTermMonths)', frequency: '#(td.repaymentFrequency)', productCode: '#(td.selectedProductCode)' }
    * if (schedFirstRepay) karate.set('regenReq', karate.merge(regenReq, { startDate: schedFirstRepay, repaymentStartDate: schedFirstRepay }))
    * if (isManualProduct && td.autoPopulationMethod) karate.set('regenReq', karate.merge(regenReq, { autoPopulationMethod: td.autoPopulationMethod }))
    * def schedRes = (isSkipSetup || isOd) ? null : karate.http(baseUrl + '/v1/loan-setup/' + appId + '/regenerate-schedule').header('Authorization', setupAuthHeader).header('Content-Type', 'application/json').post(regenReq)
    * if (schedRes != null && schedRes.status != 200) karate.fail('[SB-POST] regenerate-schedule returned HTTP ' + schedRes.status + ': ' + karate.pretty(schedRes.body))
    * def installmentsList = (schedRes == null) ? [] : (schedRes.body.installments ? schedRes.body.installments : schedRes.body)
    * def periodMonths = function(f) { var m = { MONTHLY: 1, BI_MONTHLY: 2, QUARTERLY: 3, HALF_YEARLY: 6, SEMI_ANNUAL: 6, ANNUAL: 12, YEARLY: 12 }; var k = ('' + f).toUpperCase().replace(/-/g, '_'); return m[k] ? m[k] : null }
    * def expectedInstallments = periodMonths(td.repaymentFrequency) ? Math.ceil(calcTermMonths / periodMonths(td.repaymentFrequency)) : calcTermMonths
    * expect(schedRes != null, karate.sizeOf(installmentsList), expectedInstallments, 'installments vs effective tenure and repayment frequency')
    # The setup schedule must come from CBS (ISO due dates), not LO's local fallback ("15 Oct 2026" dates),
    # which the server returns with HTTP 200 whenever its CBS call fails.
    * def isIsoDate = function(d) { return d != null && /^\d{4}-\d{2}-\d{2}/.test('' + d) }
    * if (schedRes != null && karate.sizeOf(installmentsList) > 0 && !isIsoDate(installmentsList[0].dueDate)) karate.fail('[SETUP SCHEDULE NOT FROM CBS] TestCase ' + td.testCaseId + ': Loan Setup regenerate returned the local fallback schedule (first due date ' + installmentsList[0].dueDate + ') - the CBS call failed inside LO')
    * print '✔ [SB-POST] Step 18b: Schedule -> tenure months', calcTermMonths, '| frequency', td.repaymentFrequency, '| expected installments', expectedInstallments, '| installments', karate.sizeOf(installmentsList)

    * def setupPayload =
    """
    {
      "settlementMode": "#(td.setupSettlementMode)",
      "repaymentAccountNumber": "#(td.repaymentAccountNumber)",
      "feeFundingAccountNumber": "#(td.feeFundingAccountNumber)",
      "disbursementMode": "#(td.disbursementMode)",
      "disbursementDate": "#(td.disbursementDate)",
      "disbursementAccountNumber": "#(td.disbursementAccountNumber)",
      "disbursementNotes": "#(td.disbursementNotes)"
    }
    """
    * if (!isSkipSetup) karate.call('classpath:features/loans/loan-setup-save-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: setupPayload })
    # Create Loan Account in CBS with the request the UI's Loan Setup screen builds (buildCreateAccountRequest,
    # the same builder as 04): applicants, product, purpose, amount, term, dates, settlement and the rate id.
    # The stub /send-to-cbs fallback (LN-<year>-BLR-<appId> invented locally, no CBS call) is no longer used:
    # a loan account that CBS did not create fails the row.
    * def bdRes = isSkipSetup ? null : karate.http(baseUrl + '/v1/system/business-date').header('Authorization', setupAuthHeader).get()
    * def cbsBusinessDate = (bdRes != null && bdRes.status == 200 && bdRes.body.businessDate) ? ('' + bdRes.body.businessDate).substring(0, 10) : null
    * def setupGet = isSkipSetup ? null : karate.http(baseUrl + '/v1/loan-setup/' + appId).header('Authorization', setupAuthHeader).get()
    * def setupDto = (setupGet != null && setupGet.status == 200) ? setupGet.body : {}
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
    * def createAccountPayload = (isSkipSetup || isOd) ? null : buildCreateAccountRequest(setupDto, {}, { businessDate: cbsBusinessDate, loanStartDate: td.loanStartDate, loanAmount: td.loanAmount, termMonths: calcTermMonths, disbursementDate: td.disbursementDate, repaymentStartDate: schedFirstRepay, disbAcct: td.disbursementAccountNumber, repaymentAcct: td.repaymentAccountNumber, settlementMode: (td.setupSettlementMode ? td.setupSettlementMode : td.settlementMode), feeAcct: feeAcct, repaymentFrequency: td.repaymentFrequency, disbursementMode: td.disbursementMode, commitmentId: td.commitmentId, pep: null, autoPopulationMethod: ((isManualProduct && td.autoPopulationMethod) ? td.autoPopulationMethod : null) })
    * if (!isSkipSetup && !isOd) karate.log('[cbs] create-account request - TestCase', td.testCaseId, ':', createAccountPayload)
    * def cbsPayload = { setupOfficerNotes: '#(td.setupOfficerNotes)' }
    # SETUP charges (setupCharges) before the account is created in CBS
    * def setupCharges = isSkipSetup ? null : stageCharges(setupAuthHeader, 'SETUP', 'setupCharges', appId, td, feeAcct)
    * if (setupCharges != null && setupCharges.error) karate.fail('[charges SETUP] TestCase ' + td.testCaseId + ': ' + setupCharges.error)
    * print '✔ [SB-POST] Setup charges -> collected', (setupCharges != null ? setupCharges.collected : 'skipped'), '| waived', (setupCharges != null ? setupCharges.waived : '-')
    * def cbsCreate = (isSkipSetup || isOd) ? null : karate.call('classpath:features/loans/loan-setup-cbs-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, requestBody: cbsPayload, createAccountPayload: createAccountPayload })

    # Overdraft: a NEW current account is opened with od-cs-account-create-helper (the server then completes the
    # application); an EXISTING linked account is already in CBS. The OD limit and debit rate follow.
    * def odApp = (isOd && !isSkipSetup) ? karate.http(baseUrl + '/v1/loans/' + appId).header('Authorization', setupAuthHeader).get().body : null
    * def odChoice = (odApp != null && odApp.extendedData && odApp.extendedData.odAccountChoice) ? ('' + odApp.extendedData.odAccountChoice).toUpperCase() : ''
    * def odLinked = odApp == null ? null : (odApp.odLinkedAccount ? odApp.odLinkedAccount : val(td.odLinkedAccount))
    * def odIsNew = odChoice == 'NEW' || (odChoice != 'EXISTING' && odLinked == null)
    * def csReq = { customerId: '#(td.customerId)', productId: '#(td.selectedProductCode)', accountOwnership: 'SOLE' }
    * if (val(td.accountOpenBranch) != null) karate.set('csReq', karate.merge(csReq, { branchCode: val(td.accountOpenBranch) }))
    * def odCs = (odApp != null && odIsNew) ? karate.call('classpath:features/loans/od-cs-account-create-helper.feature', { appId: appId, authHeader: setupAuthHeader, baseUrl: baseUrl, testCaseId: td.testCaseId, requestBody: csReq }) : null
    * def odAccountId = odCs != null ? odCs.accountId : odLinked
    * if (odApp != null && !odAccountId) karate.fail('[OD ACCOUNT MISSING] TestCase ' + td.testCaseId + ': no account was opened in CBS and the application has no linked account')
    * def odLimitRate =
    """
    function(a) {
      var limit = { debitLimit: { currency: a.loanAmountCurrency ? a.loanAmountCurrency : td.loanAmountCurrency, value: '' + a.loanAmount }, limitIndicator: 'DRLIMAPPCRNA', limitExcessAction: 'DNTALLOWEXCESS' };
      if (a.limitExpiryDate) limit.limitExpiryDate = ('' + a.limitExpiryDate).substring(0, 10);
      if (a.reviewDate) limit.limitReviewDate = ('' + a.reviewDate).substring(0, 10);
      var margin = a.customerMarginInterest != null ? Number(a.customerMarginInterest) : 0;
      var base = a.debitBaseCode ? ('' + a.debitBaseCode).trim() : '';
      var rate = base != '' ? { baseCode: base } : { fixedRate: (a.fixedInterestRate != null ? Number(a.fixedInterestRate) : 0) + margin };
      if (base != '' && margin != 0) rate.interestMarginDetails = { margin: (a.debitInterestMargin != null ? Number(a.debitInterestMargin) : 0) + margin, marginType: 'FLATVALUE' };
      return { limit: limit, rate: rate };
    }
    """
    * def odReqs = odApp != null ? odLimitRate(odApp) : null
    * def odCbs = odApp != null ? karate.call('classpath:features/loans/od-limit-rate-helper.feature', { appId: appId, accountId: odAccountId, authHeader: setupAuthHeader, baseUrl: baseUrl, testCaseId: td.testCaseId, limitRequest: odReqs.limit, rateRequest: odReqs.rate }) : null
    * if (odApp != null) karate.log('✔ [SB-POST] Step 18c: overdraft account', odAccountId, (odCs != null ? 'opened in CBS' : '(existing, linked)'), '| limit', odReqs.limit.debitLimit.value, odReqs.limit.debitLimit.currency)

    # Step 19: COMPLETED + CBS account number
    Given path '/v1/loans/' + appId
    And retry until response.status == 'COMPLETED' || isSkipSetup
    When method GET
    Then status 200
    * expect(!isSkipSetup, response.status, 'COMPLETED', 'final status after loan setup')
    * def finalStatus = response.status
    * def setupRes = isSkipSetup ? { status: 0 } : karate.http(baseUrl + '/v1/loan-setup/' + appId).header('Authorization', (setupAuthHeader != null ? setupAuthHeader : (acceptorAuthHeader != null ? acceptorAuthHeader : issuerAuthHeader))).get()
    # The account number must be the one CBS returned to /create-account for THIS application, stored on its
    # setup - never the local stub pattern LN-<year>-BLR-<appId> - and not the latest row of blo_loan_setup.
    * def cbsLoanIdCreated = (cbsCreate != null && cbsCreate.cbsLoanId) ? cbsCreate.cbsLoanId : (odApp != null ? odAccountId : null)
    * if (!isSkipSetup && cbsLoanIdCreated == null) karate.fail('[CBS LOAN ACCOUNT NOT CREATED] TestCase ' + td.testCaseId + ': /create-account returned no loan id')
    * if (cbsLoanIdCreated != null && (cbsCreate != null || odCs != null) && setupRes.status == 200 && setupRes.body.cbsLoanAccountNumber != cbsLoanIdCreated) karate.fail('[CBS ACCOUNT MISMATCH] TestCase ' + td.testCaseId + ': CBS returned loan id ' + cbsLoanIdCreated + ' but the setup stores ' + setupRes.body.cbsLoanAccountNumber)
    * if (cbsLoanIdCreated != null && /^LN-\d{4}-BLR-\d{6}$/.test('' + cbsLoanIdCreated)) karate.fail('[CBS ACCOUNT IS THE LOCAL STUB] TestCase ' + td.testCaseId + ': ' + cbsLoanIdCreated + ' was generated by LO, not by CBS')
    * def generatedCbsAccountNo = cbsLoanIdCreated != null ? cbsLoanIdCreated : 'N/A'
    * print '✔ [SB-POST] Step 19:', finalStatus, '| CBS account:', generatedCbsAccountNo
    * def logout = function(token) { if (token) karate.call('classpath:features/auth/logout-helper.feature', { authHeader: token }) }
    * logout(issuerAuthHeader)
    * logout(acceptorAuthHeader)
    * logout(setupAuthHeader)
