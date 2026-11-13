@ignore
Feature: Verify the sheet's loan purpose is one the product type actually offers

  # Called from the lifecycle features once the officer is signed in:
  #
  #   * def purpose = karate.call('classpath:features/loans/purpose-check-helper.feature',
  #       { baseUrl: baseUrl, authHeader: officerAuthHeader, productTypeCode: 'PL005_DYNAMIC', loanPurpose: td.loanPurpose })
  #   purpose.valueCode / purpose.label are the matched dropdown entry.
  #
  # The origination wizard's Purpose dropdown lists GET /v1/product-types/{code}/purposes — the
  # LOAN_PURPOSE options attached to the product type (configured from the Excel setup sheet). The
  # server stores whatever text a draft sends, so a sheet purpose that is not in that dropdown
  # would silently create an application no user could have created in the UI. This fails instead.
  #
  # The sheet value may be the option's label ("Personal Purpose") or its code ("002");
  # matching is case-insensitive.

  Scenario: Match the sheet purpose against the product type's purposes
    * def wanted = (typeof loanPurpose !== 'undefined' && loanPurpose != null) ? loanPurpose.toString().trim() : ''
    # `path` URL-encodes each segment — a product type code may contain a space ("COMMERCIAL LOAN").
    Given url baseUrl
    And path 'v1', 'product-types', productTypeCode, 'purposes'
    And header Authorization = authHeader
    When method GET
    Then status 200
    * def options = response
    * def describe = function() { var out = []; for (var i = 0; i < options.length; i++) { out.push(options[i].valueCode + ' = ' + options[i].label); } return out.join(', '); }
    * def matched =
      """
      function() {
        if (wanted == '') return null;
        var w = wanted.toLowerCase();
        for (var i = 0; i < options.length; i++) {
          var code = options[i].valueCode != null ? ('' + options[i].valueCode).toLowerCase() : '';
          var label = options[i].label != null ? ('' + options[i].label).toLowerCase() : '';
          if (code == w || label == w) return { valueCode: options[i].valueCode, label: options[i].label };
        }
        return null;
      }
      """
    * def purpose = matched()
    * if (options.length == 0) karate.fail('Product type ' + productTypeCode + ' has NO purposes linked - the Purpose dropdown in origination would be empty. Add them to linkedPurposes in Product-Configuration-Automation.xlsx (use the dropdown labels or codes) and re-run the configuration setup.')
    * if (wanted != '' && purpose == null) karate.fail('Sheet loanPurpose "' + wanted + '" is not in the Purpose dropdown of product type ' + productTypeCode + '. Dropdown: ' + describe() + '. Either use one of those in the lifecycle sheet, or add "' + wanted + '" to linkedPurposes in Product-Configuration-Automation.xlsx and re-run the configuration setup.')
    * if (wanted == '') karate.log('[purpose-check] sheet has no loanPurpose; dropdown for ' + productTypeCode + ': ' + describe())
    * if (purpose != null) karate.log('[purpose-check] "' + wanted + '" -> ' + purpose.valueCode + ' (' + purpose.label + ') on ' + productTypeCode)
