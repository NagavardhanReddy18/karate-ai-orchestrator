@config-setup @unified-config-setup @data-driven
Feature: Unified Configuration Setup - Scorecards, Product Types, Document Checklists, Incident Charges, Notification Templates, Notification Rules, Approval Limits

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads Unified-Configuration-Automation.xlsx across all 7 configuration sheets:
  #   1. Scorecards             (create / publish a new version / deactivate; attach to product types)
  #   2. Product_Types          (type + role access + extended fields + sub-products + purposes; DELETE cascades)
  #   3. Document_Checklists    (categories, document types, checklist, attachments to types / sub-products)
  #   4. Incident_Charges       (charge definitions, attachments to types / sub-products)
  #   5. Notification_Templates (SMS and EMAIL message templates)
  #   6. Notification_Rules     (event, conditions, channels, recipients, templates per channel)
  #   7. Approval_Limits        (User / Role / Credit Committee limits per loan type)
  #
  # Every sheet has a `run` column (Y / N) and the flags `create`, `amend`, `delete` (true / false).
  # Semantics (verified against the backend sources 2026-09-17):
  #   create = true : make the record match the sheet - created when missing, amended when it differs.
  #   amend  = true : same, but the record MUST already exist (otherwise the row fails).
  #   delete = true : remove the record; everything that references it is detached first.
  # A row with several flags set is executed in every matching phase.
  #
  # Execution is phased to honour the cross-sheet dependencies:
  #   Phase 1: CREATE  Scorecards -> Product Types -> Checklists -> Charges -> Templates -> Rules -> Limits
  #   Phase 2: AMEND   same order
  #   Phase 3: DELETE  Limits -> Rules -> Templates -> Charges -> Checklists -> Product Types [cascade] -> Scorecards
  # Rows of one phase run one by one; a failing row does NOT stop the others - the phase fails at the end
  # listing every failed row with the server's own reason.
  #
  # Governed changes (maker-checker 202 / ChangeRequest) are approved by a four-eyes checker and committed.

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Unified-Configuration-Automation.xlsx')
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def actionOf = function(x) { return (x.action == null || ('' + x.action).trim() == '') ? '' : ('' + x.action).trim().toUpperCase(); }
    * def isRunnable =
      """
      function(x) {
        if (x.run == null || ('' + x.run).trim() == '') {
          return isTrue(x.create) || isTrue(x.crete) || isTrue(x.amend) || isTrue(x.delete) || actionOf(x) != '';
        }
        return isTrue(x.run);
      }
      """
    * def isCreateRow = function(x) { return isRunnable(x) && (isTrue(x.create) || isTrue(x.crete) || actionOf(x) == 'CREATE'); }
    * def isAmendRow = function(x) { return isRunnable(x) && (isTrue(x.amend) || actionOf(x) == 'AMEND'); }
    * def isDeleteRow = function(x) { return isRunnable(x) && (isTrue(x.delete) || actionOf(x) == 'DELETE'); }
    * def rowId = function(r) { var keys = ['scorecardId', 'configId', 'checklistId', 'chargeId', 'templateId', 'ruleId', 'limitId']; for (var i = 0; i < keys.length; i++) { if (r[keys[i]] != null && ('' + r[keys[i]]).trim() != '') return '' + r[keys[i]]; } return 'row'; }
    * def load =
      """
      function(sheet) {
        var raw = ExcelDataLoader.load(excelPath, sheet);
        return { create: karate.filter(raw, isCreateRow), amend: karate.filter(raw, isAmendRow), remove: karate.filter(raw, isDeleteRow) };
      }
      """
    # Runs the helper once per row with the phase's action, collecting failures instead of stopping at the first one.
    * def runRows =
      """
      function(feature, rows, act, kind) {
        var failures = [];
        for (var i = 0; i < rows.length; i++) {
          var extra = { action: act };
          if (kind != null) extra._kind = kind;
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
  Scenario: 0. Unified Setup Overview
    * print '========================================================================'
    * print 'STARTING UNIFIED CONFIGURATION EXECUTION on', baseUrl
    * print 'Workbook:', excelPath
    * print 'Phase 1 - CREATE : Scorecards=' + sc.create.length + ', ProductTypes=' + pt.create.length + ', Checklists=' + dcl.create.length + ', Charges=' + chg.create.length + ', Templates=' + tpl.create.length + ', Rules=' + rul.create.length + ', Limits=' + lim.create.length
    * print 'Phase 2 - AMEND  : Scorecards=' + sc.amend.length + ', ProductTypes=' + pt.amend.length + ', Checklists=' + dcl.amend.length + ', Charges=' + chg.amend.length + ', Templates=' + tpl.amend.length + ', Rules=' + rul.amend.length + ', Limits=' + lim.amend.length
    * print 'Phase 3 - DELETE : Limits=' + lim.remove.length + ', Rules=' + rul.remove.length + ', Templates=' + tpl.remove.length + ', Charges=' + chg.remove.length + ', Checklists=' + dcl.remove.length + ', ProductTypes=' + pt.remove.length + ', Scorecards=' + sc.remove.length
    * print '========================================================================'

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 1: CREATE (dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 1. CREATE Scorecards
    * print '--- Phase 1.1: CREATE Scorecards (' + sc.create.length + ' rows) ---'
    * if (sc.create.length > 0) runRows(SC, sc.create, 'CREATE', null)

  Scenario: 2. CREATE Product Types
    * print '--- Phase 1.2: CREATE Product Types (' + pt.create.length + ' rows) ---'
    * if (pt.create.length > 0) runRows(PT, pt.create, 'CREATE', null)

  Scenario: 3. CREATE Document Checklists
    * print '--- Phase 1.3: CREATE Document Checklists (' + dcl.create.length + ' rows) ---'
    * if (dcl.create.length > 0) runRows(DCL, dcl.create, 'CREATE', null)

  Scenario: 4. CREATE Incident Charges
    * print '--- Phase 1.4: CREATE Incident Charges (' + chg.create.length + ' rows) ---'
    * if (chg.create.length > 0) runRows(CHG, chg.create, 'CREATE', null)

  Scenario: 5. CREATE Notification Templates
    * print '--- Phase 1.5: CREATE Notification Templates (' + tpl.create.length + ' rows) ---'
    * if (tpl.create.length > 0) runRows(NTF, tpl.create, 'CREATE', 'TEMPLATE')

  Scenario: 6. CREATE Notification Rules
    * print '--- Phase 1.6: CREATE Notification Rules (' + rul.create.length + ' rows) ---'
    * if (rul.create.length > 0) runRows(NTF, rul.create, 'CREATE', 'RULE')

  Scenario: 7. CREATE Approval Limits
    * print '--- Phase 1.7: CREATE Approval Limits (' + lim.create.length + ' rows) ---'
    * if (lim.create.length > 0) runRows(LIM, lim.create, 'CREATE', null)

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 2: AMEND (dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 8. AMEND Scorecards
    * print '--- Phase 2.1: AMEND Scorecards (' + sc.amend.length + ' rows) ---'
    * if (sc.amend.length > 0) runRows(SC, sc.amend, 'AMEND', null)

  Scenario: 9. AMEND Product Types
    * print '--- Phase 2.2: AMEND Product Types (' + pt.amend.length + ' rows) ---'
    * if (pt.amend.length > 0) runRows(PT, pt.amend, 'AMEND', null)

  Scenario: 10. AMEND Document Checklists
    * print '--- Phase 2.3: AMEND Document Checklists (' + dcl.amend.length + ' rows) ---'
    * if (dcl.amend.length > 0) runRows(DCL, dcl.amend, 'AMEND', null)

  Scenario: 11. AMEND Incident Charges
    * print '--- Phase 2.4: AMEND Incident Charges (' + chg.amend.length + ' rows) ---'
    * if (chg.amend.length > 0) runRows(CHG, chg.amend, 'AMEND', null)

  Scenario: 12. AMEND Notification Templates
    * print '--- Phase 2.5: AMEND Notification Templates (' + tpl.amend.length + ' rows) ---'
    * if (tpl.amend.length > 0) runRows(NTF, tpl.amend, 'AMEND', 'TEMPLATE')

  Scenario: 13. AMEND Notification Rules
    * print '--- Phase 2.6: AMEND Notification Rules (' + rul.amend.length + ' rows) ---'
    * if (rul.amend.length > 0) runRows(NTF, rul.amend, 'AMEND', 'RULE')

  Scenario: 14. AMEND Approval Limits
    * print '--- Phase 2.7: AMEND Approval Limits (' + lim.amend.length + ' rows) ---'
    * if (lim.amend.length > 0) runRows(LIM, lim.amend, 'AMEND', null)

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 3: DELETE (reverse dependency order)
  # ══════════════════════════════════════════════════════════════════════════
  Scenario: 15. DELETE Approval Limits
    * print '--- Phase 3.1: DELETE Approval Limits (' + lim.remove.length + ' rows) ---'
    * if (lim.remove.length > 0) runRows(LIM, lim.remove, 'DELETE', null)

  Scenario: 16. DELETE Notification Rules
    * print '--- Phase 3.2: DELETE Notification Rules (' + rul.remove.length + ' rows) ---'
    * if (rul.remove.length > 0) runRows(NTF, rul.remove, 'DELETE', 'RULE')

  Scenario: 17. DELETE Notification Templates
    * print '--- Phase 3.3: DELETE Notification Templates (' + tpl.remove.length + ' rows) ---'
    * if (tpl.remove.length > 0) runRows(NTF, tpl.remove, 'DELETE', 'TEMPLATE')

  Scenario: 18. DELETE Incident Charges
    * print '--- Phase 3.4: DELETE Incident Charges (' + chg.remove.length + ' rows) ---'
    * if (chg.remove.length > 0) runRows(CHG, chg.remove, 'DELETE', null)

  Scenario: 19. DELETE Document Checklists
    * print '--- Phase 3.5: DELETE Document Checklists (' + dcl.remove.length + ' rows) ---'
    * if (dcl.remove.length > 0) runRows(DCL, dcl.remove, 'DELETE', null)

  Scenario: 20. DELETE Product Types (with cascade)
    * print '--- Phase 3.6: DELETE Product Types [cascade] (' + pt.remove.length + ' rows) ---'
    * if (pt.remove.length > 0) runRows(PT, pt.remove, 'DELETE', null)

  Scenario: 21. DELETE Scorecards
    * print '--- Phase 3.7: DELETE Scorecards (' + sc.remove.length + ' rows) ---'
    * if (sc.remove.length > 0) runRows(SC, sc.remove, 'DELETE', null)
