@inspect-crud
Feature: Inspect CRUD-Configurations-Automation.xlsx

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/CRUD-Configurations-Automation.xlsx')
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def isRunnable =
      """
      function(x) {
        if (x.run == null || ('' + x.run).trim() == '') {
          return isTrue(x.create) || isTrue(x.amend) || isTrue(x.deactivate) || isTrue(x.delete);
        }
        return isTrue(x.run);
      }
      """

  Scenario: Show enabled rows in every sheet
    * def sheets = ['Scorecards', 'Product_Types', 'Document_Checklists', 'Incident_Charges', 'Notification_Templates', 'Notification_Rules', 'Approval_Limits']
    * eval
      """
      for (var s = 0; s < sheets.length; s++) {
        var sheet = sheets[s];
        var all = ExcelDataLoader.load(excelPath, sheet);
        var enabled = karate.filter(all, isRunnable);
        karate.log('=== Sheet: ' + sheet + ' | Total rows: ' + all.length + ' | Enabled: ' + enabled.length + ' ===');
        for (var i = 0; i < enabled.length; i++) {
          karate.log('  Row ' + (i+1) + ': ' + JSON.stringify(enabled[i]));
        }
        if (enabled.length == 0) karate.log('  (no enabled rows)');
      }
      """
