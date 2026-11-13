@ignore
Feature: Verify the sheet's extendedData covers the product type's extended fields

  # Called from the lifecycle features once the officer is signed in:
  #
  #   * def ext = karate.call('classpath:features/loans/extended-fields-check-helper.feature',
  #       { baseUrl: baseUrl, authHeader: officerAuthHeader, productTypeCode: 'AUTO_TERM_LOAN', extendedData: td.extendedData, testCaseId: td.testCaseId })
  #   ext.extendedDataObj is the parsed object to send as "extendedData" on the draft.
  #
  # The origination wizard renders GET /v1/product-types/{code}/fields (the extendedFields column of
  # Product-Configuration-Automation.xlsx) and will not move on while a required one is blank. The
  # server validates extendedData only when the draft carries some, so a sheet that omits a required
  # field would create an application no user could have created in the UI. This fails instead.
  #
  # The sheet column extendedData is a JSON object keyed by fieldKey, e.g.
  #   {"autotermvehcle":"Toyota Corolla","autotermvehcleyear":2022}
  # Blank is fine for a product type without extended fields (or with only optional ones).

  Scenario: Match the sheet extendedData against the product type's field definitions
    * def tag = '[' + ((typeof testCaseId !== 'undefined' && testCaseId != null) ? testCaseId : '?') + ']'
    * def raw = (typeof extendedData !== 'undefined' && extendedData != null) ? ('' + extendedData).trim() : ''
    * def bad = function(msg) { karate.fail(msg); throw new Error(msg); }
    * def parsed =
      """
      function() {
        if (raw == '') return {};
        var x;
        try { x = JSON.parse(raw); } catch (e) { bad(tag + ' column "extendedData" is not valid JSON: ' + e); }
        if (x == null || Array.isArray(x) || typeof x !== 'object') bad(tag + ' column "extendedData" must be a JSON object like {"fieldKey":"value"}');
        return x;
      }
      """
    * def values = parsed()
    # `path` URL-encodes each segment — a product type code may contain a space ("COMMERCIAL LOAN").
    Given url baseUrl
    And path 'v1', 'product-types', productTypeCode, 'fields'
    And header Authorization = authHeader
    When method GET
    Then status 200
    * def fields = response
    * def check =
      """
      function() {
        var missing = [], unknown = [], defined = [], known = {};
        for (var i = 0; i < fields.length; i++) {
          var f = fields[i];
          if (f.active === false) continue;
          known[f.fieldKey] = true;
          defined.push(f.fieldKey + ' (' + f.label + ', ' + f.dataType + (f.required ? ', required' : '') + ')');
          var v = values[f.fieldKey];
          var blank = v == null || ('' + v).trim() == '';
          if (blank && f.required) missing.push(f.fieldKey + ' (' + f.label + ', ' + f.dataType + ')');
        }
        for (var k in values) { if (!known[k]) unknown.push(k); }
        return { missing: missing, unknown: unknown, defined: defined };
      }
      """
    * def result = check()
    * if (result.missing.length > 0) karate.fail(tag + ' product type ' + productTypeCode + ' requires extended field(s) ' + result.missing.join(', ') + ' but the sheet column "extendedData" does not give them. Put a JSON object with those fieldKeys in the lifecycle sheet (the definitions come from extendedFields in Product-Configuration-Automation.xlsx).')
    * if (result.unknown.length > 0) karate.fail(tag + ' sheet column "extendedData" names field(s) ' + result.unknown.join(', ') + ' that product type ' + productTypeCode + ' does not define. Defined: ' + (result.defined.length > 0 ? result.defined.join(', ') : 'none') + '.')
    * karate.log('[extended-fields] ' + productTypeCode + ' defines ' + result.defined.length + ' field(s)' + (result.defined.length > 0 ? ' (' + result.defined.join(', ') + ')' : '') + '; sheet extendedData = ' + JSON.stringify(values))
    * def extendedDataObj = values
