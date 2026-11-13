@crud-config @config-crud @data-driven
Feature: CRUD Configurations - create / amend / delete or deactivate of Scorecards, Product Types, Document Checklists, Incident Charges, Notification Templates, Notification Rules and Approval Limits, each in its own sheet

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads CRUD-Configurations-Automation.xlsx. Every configuration screen has its own sheet, and every sheet offers
  # create, amend and the removal the screen itself offers (verified in the UI and backend sources 2026-09-18):
  #   1. Scorecards             create / amend / deactivate   (the screen has no Delete: Edit -> new draft version ->
  #                                                            Activate; Deactivate retires the ACTIVE version)
  #   2. Document_Checklists    create / amend / delete       (NOTE: 9190 currently answers 500 to amend and delete)
  #   3. Incident_Charges       create / amend / delete       (delete = governed deactivation, status INACTIVE)
  #   4. Notification_Templates create / amend / delete
  #   5. Notification_Rules     create / amend / delete
  #   6. Product_Types          create / amend / deactivate   (the ONLY sheet that attaches / detaches: scorecard,
  #                                                            checklist, charges, notification rules, sub-products,
  #                                                            purposes; deactivate needs the supervisor / checker
  #                                                            approval - there is no delete)
  #   7. Approval_Limits        create / amend / delete       (a limit names its loan type, so it comes last)
  #
  # Every sheet has a `run` column (Y / N) and one true/false flag per operation. A row with several flags set is
  # executed in every matching phase (e.g. create=true + deactivate=true creates first, then deactivates).
  #   create = true : make the record match the sheet - created when missing, amended when it differs.
  #   amend  = true : the record MUST already exist. Product_Types: only the attach* / detach* columns are applied.
  #   delete / deactivate = true : remove or retire the record; references are detached first where the server
  #                                would otherwise leave them dangling.
  #
  # Execution order honours the cross-sheet dependencies:
  #   Phase 1: CREATE      Scorecards -> Checklists -> Charges -> Templates -> Rules -> Product Types -> Limits
  #   Phase 2: AMEND       same order (so a Product_Types row can attach anything created or amended before it)
  #   Phase 3: DELETE      Limits -> Rules -> Templates -> Charges -> Checklists
  #   Phase 4: DEACTIVATE  Product Types -> Scorecards
  # Rows of one phase run one by one, in sheet order; a failing row does NOT stop the others - the phase fails at
  # the end listing every failed row with the server's own reason, and the next phase still runs.
  #
  # Governed changes (maker-checker 202 / ChangeRequest) are approved by a four-eyes checker and committed.
  # Scorecard changes are not governed (no change request) - they apply immediately, exactly like the screen.

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/CRUD-Configurations-Automation.xlsx')
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def actionOf = function(x) { return (x.action == null || ('' + x.action).trim() == '') ? '' : ('' + x.action).trim().toUpperCase(); }
    * def isRunnable =
      """
      function(x) {
        if (x.run == null || ('' + x.run).trim() == '') {
          return isTrue(x.create) || isTrue(x.amend) || isTrue(x.deactivate) || isTrue(x.delete) || actionOf(x) != '';
        }
        return isTrue(x.run);
      }
      """
    * def isCreateRow = function(x) { return isRunnable(x) && (isTrue(x.create) || actionOf(x) == 'CREATE'); }
    * def isAmendRow = function(x) { return isRunnable(x) && (isTrue(x.amend) || actionOf(x) == 'AMEND'); }
    * def isDeactivateRow = function(x) { return isRunnable(x) && (isTrue(x.deactivate) || actionOf(x) == 'DEACTIVATE'); }
    * def isDeleteRow = function(x) { return isRunnable(x) && (isTrue(x.delete) || actionOf(x) == 'DELETE'); }
    * def rowId = function(r) { var keys = ['scorecardId', 'configId', 'checklistId', 'chargeId', 'templateId', 'ruleId', 'limitId']; for (var i = 0; i < keys.length; i++) { if (r[keys[i]] != null && ('' + r[keys[i]]).trim() != '') return '' + r[keys[i]]; } return 'row'; }
    * def load =
      """
      function(sheet) {
        var raw = ExcelDataLoader.load(excelPath, sheet);
        return { create: karate.filter(raw, isCreateRow), amend: karate.filter(raw, isAmendRow), deactivate: karate.filter(raw, isDeactivateRow), remove: karate.filter(raw, isDeleteRow) };
      }
      """
    # Runs the helper once per row with the phase's action, collecting failures instead of stopping at the first one.
    * def runRows =
      """
      function(feature, rows, act, kind, mode) {
        var failures = [];
        for (var i = 0; i < rows.length; i++) {
          var extra = { action: act };
          if (kind != null) extra._kind = kind;
          if (mode != null) extra._mode = mode;
          var row = karate.merge(rows[i], extra);
          var id = rowId(row);
          karate.log('=== ' + act + ' ' + id + ' (' + (i + 1) + '/' + rows.length + ') ===');
          try {
            karate.call(feature, row);
          } catch (e) {
            var msg = '' + (e.message != null ? e.message : e);
            karate.log('=== ' + act + ' ' + id + ' FAILED: ' + msg);
            failures.push(id + ': ' + msg);
          }
        }
        if (failures.length > 0) {
          var text = failures.length + ' of ' + rows.length + ' ' + act + ' row(s) failed:\n - ' + failures.join('\n - ');
          karate.fail(text);
          throw new Error(text);
        }
        return rows.length;
      }
      """
    * def SC = 'classpath:features/loans/unified-scorecard-helper.feature'
    * def PT = 'classpath:features/loans/unified-product-type-helper.feature'
    * def DCL = 'classpath:features/loans/unified-document-checklist-helper.feature'
    * def CHG = 'classpath:features/loans/unified-incident-charge-helper.feature'
    * def NTF = 'classpath:features/loans/unified-notification-helper.feature'
    * def LIM = 'classpath:features/loans/unified-approval-limit-helper.feature'

    * def sc = load('Scorecards')
    * def pt = load('Product_Types')
    * def dcl = load('Document_Checklists')
    * def chg = load('Incident_Charges')
    * def tpl = load('Notification_Templates')
    * def rul = load('Notification_Rules')
    * def lim = load('Approval_Limits')

  # ══════════════════════════════════════════════════════════════════════════
  # SUMMARY OVERVIEW
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 0. CRUD Configurations Overview
    * print '========================================================================'
    * print 'STARTING CRUD CONFIGURATIONS EXECUTION on', baseUrl
    * print 'Workbook:', excelPath
    * print 'Phase 1 - CREATE     : Scorecards=' + sc.create.length + ', Checklists=' + dcl.create.length + ', Charges=' + chg.create.length + ', Templates=' + tpl.create.length + ', Rules=' + rul.create.length + ', ProductTypes=' + pt.create.length + ', Limits=' + lim.create.length
    * print 'Phase 2 - AMEND      : Scorecards=' + sc.amend.length + ', Checklists=' + dcl.amend.length + ', Charges=' + chg.amend.length + ', Templates=' + tpl.amend.length + ', Rules=' + rul.amend.length + ', ProductTypes=' + pt.amend.length + ', Limits=' + lim.amend.length
    * print 'Phase 3 - DELETE     : Limits=' + lim.remove.length + ', Rules=' + rul.remove.length + ', Templates=' + tpl.remove.length + ', Charges=' + chg.remove.length + ', Checklists=' + dcl.remove.length
    * print 'Phase 4 - DEACTIVATE : ProductTypes=' + pt.deactivate.length + ', Scorecards=' + sc.deactivate.length
    * print '========================================================================'

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 1: CREATE (dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 1. CREATE Scorecards
    * print '--- Phase 1.1: CREATE Scorecards (' + sc.create.length + ' rows) ---'
    * if (sc.create.length > 0) runRows(SC, sc.create, 'CREATE', null, null)

  Scenario: 1b. CREATE Document Checklists
    * print '--- Phase 1.2: CREATE Document Checklists (' + dcl.create.length + ' rows) ---'
    * if (dcl.create.length > 0) runRows(DCL, dcl.create, 'CREATE', null, null)

  Scenario: 1c. CREATE Incident Charges
    * print '--- Phase 1.3: CREATE Incident Charges (' + chg.create.length + ' rows) ---'
    * if (chg.create.length > 0) runRows(CHG, chg.create, 'CREATE', null, null)

  Scenario: 1d. CREATE Notification Templates
    * print '--- Phase 1.4: CREATE Notification Templates (' + tpl.create.length + ' rows) ---'
    * if (tpl.create.length > 0) runRows(NTF, tpl.create, 'CREATE', 'TEMPLATE', null)

  Scenario: 1e. CREATE Notification Rules
    * print '--- Phase 1.5: CREATE Notification Rules (' + rul.create.length + ' rows) ---'
    * if (rul.create.length > 0) runRows(NTF, rul.create, 'CREATE', 'RULE', null)

  Scenario: 1f. CREATE Product Types (attach what the rows above created)
    * print '--- Phase 1.6: CREATE Product Types (' + pt.create.length + ' rows) ---'
    * if (pt.create.length > 0) runRows(PT, pt.create, 'CREATE', null, null)

  Scenario: 1g. CREATE Approval Limits
    * print '--- Phase 1.7: CREATE Approval Limits (' + lim.create.length + ' rows) ---'
    * if (lim.create.length > 0) runRows(LIM, lim.create, 'CREATE', null, null)

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 2: AMEND (dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 2. AMEND Scorecards (new version, activated)
    * print '--- Phase 2.1: AMEND Scorecards (' + sc.amend.length + ' rows) ---'
    * if (sc.amend.length > 0) runRows(SC, sc.amend, 'AMEND', null, null)

  Scenario: 4. AMEND Document Checklists
    * print '--- Phase 2.2: AMEND Document Checklists (' + dcl.amend.length + ' rows) ---'
    * if (dcl.amend.length > 0) runRows(DCL, dcl.amend, 'AMEND', null, null)

  Scenario: 5. AMEND Incident Charges
    * print '--- Phase 2.3: AMEND Incident Charges (' + chg.amend.length + ' rows) ---'
    * if (chg.amend.length > 0) runRows(CHG, chg.amend, 'AMEND', null, null)

  Scenario: 6. AMEND Notification Templates
    * print '--- Phase 2.4: AMEND Notification Templates (' + tpl.amend.length + ' rows) ---'
    * if (tpl.amend.length > 0) runRows(NTF, tpl.amend, 'AMEND', 'TEMPLATE', null)

  Scenario: 7. AMEND Notification Rules
    * print '--- Phase 2.5: AMEND Notification Rules (' + rul.amend.length + ' rows) ---'
    * if (rul.amend.length > 0) runRows(NTF, rul.amend, 'AMEND', 'RULE', null)

  Scenario: 7b. AMEND Product Types (attach / detach scorecard, checklist, charges, rules, sub-products, purposes)
    * print '--- Phase 2.6: AMEND Product Types (' + pt.amend.length + ' rows) ---'
    * if (pt.amend.length > 0) runRows(PT, pt.amend, 'AMEND', null, 'LINKS')

  Scenario: 8. AMEND Approval Limits
    * print '--- Phase 2.7: AMEND Approval Limits (' + lim.amend.length + ' rows) ---'
    * if (lim.amend.length > 0) runRows(LIM, lim.amend, 'AMEND', null, null)

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 3: DELETE (reverse dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 9. DELETE Approval Limits
    * print '--- Phase 3.1: DELETE Approval Limits (' + lim.remove.length + ' rows) ---'
    * if (lim.remove.length > 0) runRows(LIM, lim.remove, 'DELETE', null, null)

  Scenario: 10. DELETE Notification Rules
    * print '--- Phase 3.2: DELETE Notification Rules (' + rul.remove.length + ' rows) ---'
    * if (rul.remove.length > 0) runRows(NTF, rul.remove, 'DELETE', 'RULE', null)

  Scenario: 11. DELETE Notification Templates
    * print '--- Phase 3.3: DELETE Notification Templates (' + tpl.remove.length + ' rows) ---'
    * if (tpl.remove.length > 0) runRows(NTF, tpl.remove, 'DELETE', 'TEMPLATE', null)

  Scenario: 12. DELETE Incident Charges (governed deactivation)
    * print '--- Phase 3.4: DELETE Incident Charges (' + chg.remove.length + ' rows) ---'
    * if (chg.remove.length > 0) runRows(CHG, chg.remove, 'DELETE', null, null)

  Scenario: 13. DELETE Document Checklists
    * print '--- Phase 3.5: DELETE Document Checklists (' + dcl.remove.length + ' rows) ---'
    * if (dcl.remove.length > 0) runRows(DCL, dcl.remove, 'DELETE', null, null)

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 4: DEACTIVATE (product types with checker approval, then scorecards)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 14. DEACTIVATE Product Types (supervisor approval)
    * print '--- Phase 4.1: DEACTIVATE Product Types (' + pt.deactivate.length + ' rows) ---'
    * if (pt.deactivate.length > 0) runRows(PT, pt.deactivate, 'DEACTIVATE', null, null)

  Scenario: 15. DEACTIVATE Scorecards
    * print '--- Phase 4.2: DEACTIVATE Scorecards (' + sc.deactivate.length + ' rows) ---'
    * if (sc.deactivate.length > 0) runRows(SC, sc.deactivate, 'DEACTIVATE', null, null)
