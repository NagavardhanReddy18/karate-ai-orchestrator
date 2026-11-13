/*
 * Expected number of schedule installments for a loan, driven by the repayment type configured on the
 * CBS sub-product (product search: repaymentType = CBS code, loRepaymentType = LO type).
 *
 * Usage in a feature:
 *   * def expectedInstallmentsFor = read('classpath:features/loans/expected-installments.js')
 *   * def instRule = expectedInstallmentsFor({ product: cbsProduct, frequency: td.repaymentFrequency, termMonths: calcTermMonths, splitInterestFrequency: !!optionFields.spec.interestFrequency })
 *   * def expectedInstallments = instRule.expected      // null = do not assert the count
 *
 * CBS code -> LO type mapping mirrors beyondlo.blo_repay_type_map (V2055__repayment_field_config.sql).
 * To support a new / changed repayment type, add or edit its entry in RULES below.
 */
function(args) {
  var product = args.product || {};
  var termMonths = Number(args.termMonths);

  // CBS repayment code -> LO repayment type (blo_repay_type_map)
  var CBS_TO_LO = { R: 'EMI', C: 'FPI', N: 'IOPM', P: 'POIM', L: 'FLAT', M: 'PAM', U: 'UPFRONT', R78: 'RULE78', K: 'MANUAL' };

  var PERIOD_MONTHS = { MONTHLY: 1, BI_MONTHLY: 2, QUARTERLY: 3, HALF_YEARLY: 6, SEMI_ANNUAL: 6, ANNUAL: 12, YEARLY: 12 };
  var freqKey = ('' + (args.frequency || '')).toUpperCase().replace(/-/g, '_');
  var period = PERIOD_MONTHS[freqKey] || null;

  // One installment per repayment period over the term.
  var perPeriod = function() {
    if (!period || !termMonths) return { expected: null, reason: 'unknown frequency "' + args.frequency + '" or term ' + args.termMonths };
    if (args.splitInterestFrequency) return { expected: null, reason: 'interest frequency differs from principal frequency - count not fixed' };
    return { expected: Math.ceil(termMonths / period), reason: termMonths + ' months / ' + period + '-month ' + freqKey + ' periods' };
  };
  var single = function(why) { return function() { return { expected: 1, reason: why } } };
  var noAssert = function(why) { return function() { return { expected: null, reason: why } } };

  // LO repayment type -> how CBS builds the schedule
  var RULES = {
    EMI:     perPeriod,                                                   // Reducing - equal installments every period
    FPI:     perPeriod,                                                   // Fixed principal + accrued interest every period
    FLAT:    perPeriod,                                                   // Flat interest - every period
    RULE78:  perPeriod,                                                   // Rule of 78 - every period
    UPFRONT: perPeriod,                                                   // Interest discounted upfront, principal every period
    IOPM:    perPeriod,                                                   // Interest every period, principal in the last one
    POIM:    perPeriod,                                                   // Principal every period, interest in the last one
    PAM:     single('Payment at Maturity - principal and interest in one installment at maturity'),
    MANUAL:  noAssert('Manual Schedule - count comes from the uploaded schedule')
  };

  var cbsCode = product.repaymentType != null ? ('' + product.repaymentType).trim().toUpperCase() : '';
  var loType = product.loRepaymentType != null ? ('' + product.loRepaymentType).trim().toUpperCase() : '';
  if (!loType && cbsCode) loType = CBS_TO_LO[cbsCode] || '';

  var rule = RULES[loType];
  var result;
  if (rule) {
    result = rule();
  } else {
    // Product not found in the search or a type not in RULES yet: keep the old frequency-based check.
    result = perPeriod();
    result.reason = 'repayment type "' + (loType || cbsCode || 'unknown') + '" has no rule - frequency-based: ' + result.reason;
  }
  result.loRepaymentType = loType || null;
  result.cbsRepaymentType = cbsCode || null;
  result.description = product.repaymentTypeDesc || null;
  return result;
}

