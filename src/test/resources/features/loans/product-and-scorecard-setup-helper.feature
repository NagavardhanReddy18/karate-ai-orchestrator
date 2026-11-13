@ignore
Feature: Dynamic Creation & Setup of Product Types and Scorecards via API

  # Called from Background / setup block of lifecycle features:
  #
  #   * karate.call('classpath:features/loans/product-and-scorecard-setup-helper.feature', {
  #       baseUrl: baseUrl,
  #       adminAuthHeader: freshAdminHeader,
  #       adminUsername: activeAdminUser,
  #       createProductType: td.createProductType,
  #       newProductTypeCode: td.newProductTypeCode,
  #       newProductTypeName: td.newProductTypeName,
  #       newProductCategory: td.newProductCategory,
  #       newWorkflowKey: td.newWorkflowKey,
  #       loanProductType: td.loanProductType,
  #       selectedProductCode: td.selectedProductCode,
  #       createScorecard: td.createScorecard,
  #       newScorecardCode: td.newScorecardCode,
  #       newScorecardName: td.newScorecardName,
  #       passScore: td.passScore,
  #       autoRejectScore: td.autoRejectScore,
  #       scorecardAttributes: td.scorecardAttributes,
  #       attachScorecardToProduct: td.attachScorecardToProduct
  #     })

  Scenario: Execute Product Type & Scorecard Setup
    * def isTrue =
      """
      function(val) {
        if (val == null) return false;
        var s = val.toString().trim().toLowerCase();
        return s == 'true' || s == 'y' || s == 'yes' || s == '1';
      }
      """

    * def isFalse =
      """
      function(val) {
        if (val == null) return true;
        var s = val.toString().trim().toLowerCase();
        return s == '' || s == 'false' || s == 'n' || s == 'no' || s == '0';
      }
      """

    * def strVal =
      """
      function(val, defVal) {
        return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal;
      }
      """

    * def getValidUrl =
      """
      function() {
        var raw = karate.get('apiBaseUrl');
        if (raw != null && raw != 'null' && String(raw).trim() != '' && String(raw).toLowerCase().startsWith('http')) {
          return String(raw).trim();
        }
        var base = karate.get('baseUrl');
        if (base != null && base != 'null' && String(base).trim() != '' && String(base).toLowerCase().startsWith('http')) {
          return String(base).trim();
        }
        var port = karate.properties['lo.test.port'];
        var portNum = (port && port.toString().trim() == '9190') ? '9190' : ((karate.env == 'test' || karate.env == '9190') ? '9190' : '9090');
        return 'http://164.52.210.93:' + portNum + '/api';
      }
      """

    * def defaultHostPort = (karate.properties['lo.test.port'] == '9190' || karate.env == 'test' || karate.env == '9190') ? 'http://164.52.210.93:9190/api' : 'http://164.52.210.93:9090/api'
    * def apiBaseUrl = getValidUrl()
    * def apiAdminAuthHeader = (typeof adminAuthHeader !== 'undefined' && adminAuthHeader != null) ? adminAuthHeader : karate.get('adminAuthHeader')
    * def apiAdminUsername = (typeof adminUsername !== 'undefined' && adminUsername != null) ? adminUsername : karate.get('adminUsername')

    * def rawCheckerUser = typeof checkerUsername !== 'undefined' ? checkerUsername : (typeof approvalUsername !== 'undefined' ? approvalUsername : (typeof setupApprovalUser !== 'undefined' ? setupApprovalUser : null))
    * def rawCheckerPass = typeof checkerPassword !== 'undefined' ? checkerPassword : (typeof approvalPassword !== 'undefined' ? approvalPassword : null)

    * def apiCheckerUsername = (rawCheckerUser != null && rawCheckerUser.toString().trim() != '') ? rawCheckerUser.toString().trim() : (karate.get('checkerUsername') || ((typeof governanceCheckers !== 'undefined' && governanceCheckers != null && governanceCheckers.length > 0) ? governanceCheckers[0].username : 'admin2'))

    * def apiCheckerPassword = (rawCheckerPass != null && rawCheckerPass.toString().trim() != '') ? rawCheckerPass.toString().trim() : (karate.get('checkerPassword') || ((typeof governanceCheckers !== 'undefined' && governanceCheckers != null && governanceCheckers.length > 0) ? governanceCheckers[0].password : 'Password@123'))

    * def reqCreateProductType = isTrue(typeof createProductType !== 'undefined' ? createProductType : null)
    * def reqCreateScorecard = isTrue(typeof createScorecard !== 'undefined' ? createScorecard : null)

    * def rawAttach = typeof attachScorecardToProduct !== 'undefined' ? attachScorecardToProduct : null
    * def reqAttachScorecard = isTrue(rawAttach) || (rawAttach != null && rawAttach.toString().trim() != '' && !isFalse(rawAttach))
    * def attachSearchTerm = (reqAttachScorecard && !isTrue(rawAttach)) ? rawAttach.toString().trim() : null

    * print '[SETUP-HELPER-DEBUG] createProductType:', typeof createProductType !== 'undefined' ? createProductType : 'undefined', '| reqCreateProductType:', reqCreateProductType
    * print '[SETUP-HELPER-DEBUG] createScorecard:', typeof createScorecard !== 'undefined' ? createScorecard : 'undefined', '| reqCreateScorecard:', reqCreateScorecard
    * print '[SETUP-HELPER-DEBUG] apiBaseUrl:', apiBaseUrl, '| apiAdminUsername:', apiAdminUsername, '| apiCheckerUsername:', apiCheckerUsername

    * eval (!reqCreateProductType && !reqCreateScorecard && !reqAttachScorecard) ? karate.log('[SETUP-HELPER] No Product Type or Scorecard setup requested — skipping.') : null

    # Helper function to auto-approve Change Requests if maker-checker returns 200 or 202
    * def handleCrResponse =
      """
      function(res, status) {
        if ((status == 200 || status == 202) && res && res.id) {
          var bUrl = getValidUrl();
          var aHeader = karate.get('apiAdminAuthHeader');
          var aUser = karate.get('apiAdminUsername');
          var cUser = karate.get('apiCheckerUsername');
          var cPass = karate.get('apiCheckerPassword');

          var crId = res.id;
          karate.log('[SETUP-HELPER] Change Request raised -> ID:', crId, '| Approving with checker:', cUser);

          // Step A: Create supervisor link if missing between maker and checker
          if (aUser != cUser) {
            var linkPayload = { userUsername: aUser, supervisorUsername: cUser, active: true };
            karate.http(bUrl + '/v1/supervisor-links')
                  .header('Authorization', aHeader)
                  .header('Content-Type', 'application/json')
                  .post(linkPayload);
          }

          // Step B: Approve Change Request via checker account
          var userToken = karate.call('classpath:features/auth/auth.feature', { username: cUser, password: cPass }).token;
          var userHeader = 'Bearer ' + userToken;
          var approveRes = karate.http(bUrl + '/v1/change-requests/' + crId + '/approve')
                                 .header('Authorization', userHeader)
                                 .header('Content-Type', 'application/json')
                                 .post({ comment: 'Approved by Dynamic Setup Helper' });
          karate.log('[SETUP-HELPER] Change Request Approved -> Status:', approveRes.status);

          // Step C: Commit Change Request
          var commitRes = karate.http(bUrl + '/v1/change-requests/' + crId + '/commit')
                                .header('Authorization', aHeader)
                                .header('Content-Type', 'application/json')
                                .post({});
          karate.log('[SETUP-HELPER] Change Request Committed -> Status:', commitRes.status);
        }
      }
      """

    # ── 1. SCORECARD CREATION ──────────────────────────────────────────────────
    * def targetScorecardCode = strVal(typeof newScorecardCode !== 'undefined' ? newScorecardCode : null, 'SC_' + strVal(typeof loanProductType !== 'undefined' ? loanProductType : null, 'DEFAULT'))
    * def targetScorecardName = strVal(typeof newScorecardName !== 'undefined' ? newScorecardName : null, targetScorecardCode + ' Scorecard')
    * def todayStr = new java.text.SimpleDateFormat("yyyy-MM-dd").format(new java.util.Date())
    * def scorecardEffectiveFrom = strVal(typeof effectiveFrom !== 'undefined' ? effectiveFrom : null, todayStr)
    * def createdScorecardId = null

    * def setupScorecardFn =
      """
      function() {
        if (reqCreateScorecard) {
          var bUrl = getValidUrl();
          var aHeader = karate.get('apiAdminAuthHeader');
          karate.log('[SETUP-HELPER] Creating Scorecard:', targetScorecardCode, '| EffectiveFrom:', scorecardEffectiveFrom);
          
          var attrList = [
            {
              attributeCode: 'CUSTOMER_AGE',
              attributeName: 'Applicant Age',
              dataSource: 'APPLICATION',
              sourceField: 'customerAge',
              dataType: 'NUMBER',
              scoringMethod: 'RANGE',
              weight: 50.0,
              scoringBands: '[{"min":0,"max":100,"score":100}]',
              active: true
            },
            {
              attributeCode: 'MONTHLY_INCOME',
              attributeName: 'Monthly Gross Income',
              dataSource: 'APPLICATION',
              sourceField: 'monthlyGrossIncome',
              dataType: 'NUMBER',
              scoringMethod: 'RANGE',
              weight: 50.0,
              scoringBands: '[{"min":0,"max":10000000,"score":100}]',
              active: true
            }
          ];

          // Parse dynamic scorecardAttributes string if passed (Format: CODE:WEIGHT:METHOD:BANDS)
          var scAttrStr = (typeof scorecardAttributes !== 'undefined' && scorecardAttributes != null) ? scorecardAttributes.toString().trim() : '';
          if (scAttrStr != '') {
            var rawAttrs = scAttrStr.split('|');
            var parsedAttrs = [];
            for (var i = 0; i < rawAttrs.length; i++) {
              var parts = rawAttrs[i].split(':');
              if (parts.length >= 2) {
                var code = parts[0];
                if (code == 'APPLICATION_AGE' || code == 'CUSTOMER_AGE') code = 'CUSTOMER_AGE';
                if (code == 'APPLICATION_MONTHLY_INCOME' || code == 'MONTHLY_GROSS_INCOME' || code == 'MONTHLY_INCOME') code = 'MONTHLY_INCOME';

                var weight = parseFloat(parts[1]);
                var method = (parts.length > 2) ? parts[2] : 'RANGE';
                var bands = (parts.length > 3) ? parts[3] : '[{"min":0,"max":999999,"score":100}]';
                parsedAttrs.push({
                  attributeCode: code,
                  attributeName: code,
                  dataSource: 'APPLICATION',
                  sourceField: code.toLowerCase(),
                  dataType: 'NUMBER',
                  scoringMethod: method,
                  weight: weight,
                  scoringBands: bands,
                  active: true
                });
              }
            }
            if (parsedAttrs.length > 0) {
              attrList = parsedAttrs;
            }
          }

          var pScore = parseFloat(strVal(typeof passScore !== 'undefined' ? passScore : null, '60'));
          var rScore = parseFloat(strVal(typeof autoRejectScore !== 'undefined' ? autoRejectScore : null, '30'));

          var scPayload = {
            scorecardDomain: 'LOAN_APPLICATION',
            code: targetScorecardCode,
            name: targetScorecardName,
            description: 'Auto-created scorecard for testing',
            passScore: pScore,
            autoRejectScore: rScore,
            maxScoreBasis: 'BAND_MAX',
            effectiveFrom: scorecardEffectiveFrom,
            attributes: attrList
          };

          var scRes = karate.http(bUrl + '/v1/config/scorecards?domain=LOAN_APPLICATION')
                            .header('Authorization', aHeader)
                            .header('Content-Type', 'application/json')
                            .post(scPayload);
          karate.log('[SETUP-HELPER] Scorecard Create Response Status:', scRes.status);
          handleCrResponse(scRes.body, scRes.status);

          // Query server to get the committed Scorecard ID by code/name
          var searchRes = karate.http(bUrl + '/v1/config/scorecards?domain=LOAN_APPLICATION')
                                .header('Authorization', aHeader)
                                .get();
          if (searchRes.status == 200 && searchRes.body && searchRes.body.length) {
            var list = searchRes.body;
            for (var i = 0; i < list.length; i++) {
              var sc = list[i];
              if ((sc.code && sc.code.toString().trim().toLowerCase() == targetScorecardCode.toLowerCase()) ||
                  (sc.name && sc.name.toString().trim().toLowerCase() == targetScorecardName.toLowerCase())) {
                createdScorecardId = sc.id;
                karate.log('[SETUP-HELPER] Matched Committed Scorecard -> ID:', createdScorecardId);
                break;
              }
            }
          }

          if (createdScorecardId != null) {
            karate.log('[SETUP-HELPER] Scorecard Created -> ID:', createdScorecardId, '| Publishing...');
            var pubRes = karate.http(bUrl + '/v1/config/scorecards/' + createdScorecardId + '/publish?effectiveFrom=' + scorecardEffectiveFrom)
                               .header('Authorization', aHeader)
                               .header('Content-Type', 'application/json')
                               .post({});
            karate.log('[SETUP-HELPER] Scorecard Published Status:', pubRes.status);
          }
        }
      }
      """
    * eval setupScorecardFn()

    # ── 2. PRODUCT TYPE CREATION ───────────────────────────────────────────────
    * def targetPtCode = strVal(typeof newProductTypeCode !== 'undefined' ? newProductTypeCode : null, strVal(typeof loanProductType !== 'undefined' ? loanProductType : null, 'DEFAULT_PT'))
    * def targetPtName = strVal(typeof newProductTypeName !== 'undefined' ? newProductTypeName : null, targetPtCode)
    * def targetCategory = strVal(typeof newProductCategory !== 'undefined' ? newProductCategory : null, strVal(typeof loanCategory !== 'undefined' ? loanCategory : null, 'RETAIL'))
    * def targetWorkflow = strVal(typeof newWorkflowKey !== 'undefined' ? newWorkflowKey : null, (targetCategory == 'OVERDRAFT' ? 'LOS_RETAIL_OD' : (targetCategory == 'ENTERPRISE' ? 'LOS_ENT_LOAN' : 'LOS_RETAIL_LOAN')))

    * def setupProductTypeFn =
      """
      function() {
        if (reqCreateProductType) {
          var bUrl = getValidUrl();
          var aHeader = karate.get('apiAdminAuthHeader');
          karate.log('[SETUP-HELPER] Creating Product Type:', targetPtCode);
          var ptPayload = {
            productType: {
              code: targetPtCode,
              label: targetPtName,
              description: 'Auto-created product type',
              category: targetCategory == 'OVERDRAFT' ? 'OVERDRAFT' : 'LOAN',
              customerType: targetCategory == 'ENTERPRISE' ? 'ENTERPRISE' : 'RETAIL',
              workflowKey: targetWorkflow,
              active: true
            },
            config: {
              productTypeCode: targetPtCode,
              assessmentMethod: 'AUTO',
              routingMethod: 'DIRECT',
              scorecardId: createdScorecardId
            }
          };

          var ptRes = karate.http(bUrl + '/v1/product-types')
                            .header('Authorization', aHeader)
                            .header('Content-Type', 'application/json')
                            .post(ptPayload);
          karate.log('[SETUP-HELPER] Product Type Create Response Status:', ptRes.status);
          karate.log('[SETUP-HELPER] Product Type Create Response Body:', ptRes.body);
          handleCrResponse(ptRes.body, ptRes.status);

          // Grant role access to LOAN_OFFICER and ADMIN roles
          var roleList = ['LOAN_OFFICER', 'ADMIN', 'MANAGER', 'UNDERWRITER'];
          for (var r = 0; r < roleList.length; r++) {
            var roleRes = karate.http(bUrl + '/v1/product-types/' + targetPtCode + '/role-access/' + roleList[r])
                                .header('Authorization', aHeader)
                                .header('Content-Type', 'application/json')
                                .post({});
            handleCrResponse(roleRes.body, roleRes.status);
          }
        }
      }
      """
    * eval setupProductTypeFn()

    # ── 3. LINK LOAN PRODUCT & ATTACH SCORECARD & PURPOSES ────────────────────
    * def targetProdCode = strVal(typeof selectedProductCode !== 'undefined' ? selectedProductCode : null, '80001DEFAULTUSD')

    * def linkAndAttachFn =
      """
      function() {
        var bUrl = getValidUrl();
        var aHeader = karate.get('apiAdminAuthHeader');
        if (reqCreateProductType) {
          // Step A: Link product code to product type
          karate.log('[SETUP-HELPER] Linking Product Code:', targetProdCode, 'to Product Type:', targetPtCode);
          var linkRes = karate.http(bUrl + '/v1/product-types/' + targetPtCode + '/products/' + targetProdCode)
                              .header('Authorization', aHeader)
                              .header('Content-Type', 'application/json')
                              .put({});
          handleCrResponse(linkRes.body, linkRes.status);

          // Step B: Link available loan purposes to product type
          karate.log('[SETUP-HELPER] Querying and linking linkable loan purposes for Product Type:', targetPtCode);
          var purpSearchRes = karate.http(bUrl + '/v1/product-types/' + targetPtCode + '/linkable-purposes')
                                    .header('Authorization', aHeader)
                                    .get();
          if (purpSearchRes.status == 200 && purpSearchRes.body && purpSearchRes.body.length > 0) {
            var pCodes = [];
            for (var p = 0; p < purpSearchRes.body.length; p++) {
              if (purpSearchRes.body[p].code) {
                pCodes.push(purpSearchRes.body[p].code);
              }
            }
            if (pCodes.length > 0) {
              karate.log('[SETUP-HELPER] Linking Purposes:', pCodes, 'to Product Type:', targetPtCode);
              var purpRes = karate.http(bUrl + '/v1/product-types/' + targetPtCode + '/purposes')
                                  .header('Authorization', aHeader)
                                  .header('Content-Type', 'application/json')
                                  .put(pCodes);
              handleCrResponse(purpRes.body, purpRes.status);
            }
          }
        }

        // Step C: Set product config with scorecard attachment
        if (reqAttachScorecard) {
            var scIdToAttach = createdScorecardId;
            var scNameToAttach = targetScorecardName;
            var scCodeToAttach = targetScorecardCode;

            // Determine lookup search term if user specified a custom name/code in attachScorecardToProduct
            var term = (attachSearchTerm != null && attachSearchTerm != '') ? attachSearchTerm : (scCodeToAttach ? scCodeToAttach : scNameToAttach);

            // If scorecard ID is missing OR user specified an existing UI scorecard name/code, query server scorecards
            if (scIdToAttach == null || (attachSearchTerm != null && attachSearchTerm != '')) {
              karate.log('[SETUP-HELPER] Querying server scorecards for match:', term);
              var searchRes = karate.http(bUrl + '/v1/config/scorecards?domain=LOAN_APPLICATION')
                                    .header('Authorization', aHeader)
                                    .get();
              if (searchRes.status == 200 && searchRes.body && searchRes.body.length) {
                var list = searchRes.body;
                for (var i = 0; i < list.length; i++) {
                  var sc = list[i];
                  var cCode = sc.code ? sc.code.toString().trim() : '';
                  var cName = sc.name ? sc.name.toString().trim() : '';
                  if ((cCode != '' && cCode.toLowerCase() == term.toLowerCase()) ||
                      (cName != '' && cName.toLowerCase() == term.toLowerCase())) {
                    scIdToAttach = sc.id;
                    scNameToAttach = sc.name;
                    scCodeToAttach = sc.code;
                    karate.log('[SETUP-HELPER] Matched Scorecard -> ID:', scIdToAttach, '| Name:', scNameToAttach, '| Code:', scCodeToAttach);
                    break;
                  }
                }
              }
            }

            karate.log('[SETUP-HELPER] Attaching Scorecard (ID:', scIdToAttach, '| Name:', scNameToAttach, ') to Product Type:', targetPtCode, '| Product Code:', targetProdCode);
            var configPayload = {
              productTypeCode: targetPtCode,
              productCode: targetProdCode,
              scorecardId: scIdToAttach,
              scorecardName: scNameToAttach,
              assessmentMethod: 'AUTO',
              routingMethod: 'DIRECT',
              active: true
            };
            var configRes = karate.http(bUrl + '/v1/product-types/' + targetPtCode + '/products/' + targetProdCode + '/config')
                                  .header('Authorization', aHeader)
                                  .header('Content-Type', 'application/json')
                                  .put(configPayload);
            handleCrResponse(configRes.body, configRes.status);
          }
        }
      """
    * eval linkAndAttachFn()
