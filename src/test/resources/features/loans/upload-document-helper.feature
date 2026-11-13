@ignore
Feature: Helper to Upload Document during Origination or Assessment

  Background:
    * url baseUrl
    * configure headers = { Authorization: '#(authHeader)' }

  Scenario: Upload Document by Application Ref or Application ID
    * def docFileName = docName ? docName : 'National_ID_Proof.pdf'
    * def isRefUpload = typeof appRef != 'undefined' && appRef != null

    # 1. Upload Document via multipart form-data
    Given path isRefUpload ? '/v1/documents/upload-by-ref' : '/v1/documents/upload'
    And multipart field applicationRef = isRefUpload ? appRef : ''
    And multipart field applicationId = !isRefUpload ? appId : ''
    And multipart field documentType = docType
    And multipart field documentName = docFileName
    And multipart field phase = 'ORIGINATION'
    And multipart file file = { read: 'classpath:dummy-document.txt', filename: '#(docFileName)', contentType: 'text/plain' }
    When method POST
    Then assert responseStatus == 200 || responseStatus == 201
    * def uploadedDocId = response.id
    * print 'Document Uploaded Successfully - Doc ID:', uploadedDocId

    # 2. Update Document Status (Valid backend statuses: PENDING_REVIEW, APPROVED, REJECTED, NEEDS_REVISION)
    * def targetStatus = docStatus ? docStatus : 'APPROVED'
    * def statusComment = docComment ? docComment : 'Verified during Origination step'
    Given path '/v1/documents/' + uploadedDocId + '/status'
    And param status = targetStatus
    And param comments = statusComment
    When method PUT
    Then assert responseStatus == 200 || responseStatus == 204
    * print 'Document Status Updated to:', targetStatus, 'for Doc ID:', uploadedDocId
