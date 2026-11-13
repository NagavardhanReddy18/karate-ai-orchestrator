@ignore
Feature: Pre-Checklist Auto-Healing Helper (Stage Compliance Gate)

  # Usage:
  #   * karate.call('classpath:features/loans/pre-checklist-auto-heal-helper.feature', { baseUrl: baseUrl, authHeader: authHeader, appRef: appRef, stage: 'APPLICATION' })
  #
  # Supported stages: APPLICATION, ASSESSMENT, ISSUE_OFFER, ACCEPT_OFFER, SETUP
  # Safely no-ops if the endpoint is absent (404) or no mandatory/blockOnNo items remain unanswered.

  Scenario: Discover and auto-complete pending mandatory/blocking pre-checklist items
    Given url baseUrl
    And path '/v1/pre-checklist/' + appRef + '/' + stage
    And header Authorization = authHeader
    When method GET
    * def checklistStatus = responseStatus
    * def view = response
    * def pendingAnswers =
      """
      function() {
        if (checklistStatus != 200 || !view || !view.editable || !view.items) return [];
        var out = [];
        for (var i = 0; i < view.items.length; i++) {
          var item = view.items[i];
          if (item.retired) continue;
          var needsAnswer = (item.mandatory === true && (item.response == null || item.response === ''))
                         || (item.blockOnNo === true && (item.response == null || item.response === '' || item.response === 'NO'));
          if (needsAnswer) {
            out.push({
              valueCode: item.valueCode,
              response: 'YES',
              remarks: 'Auto-completed by Pre-Checklist Self-Healing Agent',
              version: item.version
            });
          }
        }
        return out;
      }
      """
    * def answersToSave = pendingAnswers()
    * if (karate.sizeOf(answersToSave) > 0) karate.log('[PreChecklistAutoHeal] Stage', stage, 'for', appRef, '-> healing', karate.sizeOf(answersToSave), 'item(s)')
    * def saveRes = karate.sizeOf(answersToSave) > 0 ? karate.http(baseUrl + '/v1/pre-checklist/' + appRef + '/' + stage).header('Authorization', authHeader).header('Content-Type', 'application/json').put({ answers: answersToSave }) : null
    * if (saveRes != null && saveRes.status != 200) karate.fail('[PreChecklistAutoHeal] Failed saving pre-checklist for stage ' + stage + ': HTTP ' + saveRes.status + ' ' + karate.toString(saveRes.body))
    * if (saveRes != null) karate.log('✔ [PreChecklistAutoHeal] Stage', stage, 'healed successfully.')
