"""
Excel → JSON Converter for Karate Data-Driven Loan Lifecycle Tests
==================================================================
Usage:
    pip install openpyxl
    python excel-to-json-converter.py

Input:  loan-lifecycle-test-data.xlsx  (in the same folder as this script)
Output: loan-lifecycle-test-data.json  (in the same folder — auto-overwrites)

Excel Column Headers (Row 1 must match EXACTLY):
  testCaseId, description,
  loanCategory, customerTypeSelected, customerId, customerName,
  loanPurpose, loanAmount, loanAmountCurrency, totalAmount, totalAmountCurrency,
  customerContribution, loanTerm, termFrequency,
  selectedProductCode, selectedProductName, loanProductType,
  interestType, repaymentFrequency, monthlyGrossIncome, existingEmiObligations,
  approvalLimitPartyType, approvalLimitFacilityType, approvalLimitAmount,
  overriddenInterestRate,
  settlementMode, repaymentAccountNumber, feeFundingAccountNumber,
  disbursementMode, disbursementDate, disbursementAccountNumber, disbursementNotes,
  offerValidityDate, offerRateAdjustment, offerPrincipalReduction
"""

import json
import os
import sys

try:
    import openpyxl
except ImportError:
    print("ERROR: openpyxl is not installed. Run:  pip install openpyxl")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
EXCEL_FILE   = os.path.join(SCRIPT_DIR, "loan-lifecycle-test-data.xlsx")
JSON_FILE    = os.path.join(SCRIPT_DIR, "loan-lifecycle-test-data.json")

# Columns that should be stored as numbers (not strings) in JSON
NUMERIC_COLS = {
    "loanAmount", "totalAmount", "customerContribution",
    "loanTerm", "monthlyGrossIncome", "existingEmiObligations",
    "approvalLimitAmount", "overriddenInterestRate",
    "offerRateAdjustment", "offerPrincipalReduction"
}

# ---------------------------------------------------------------------------
# Conversion logic
# ---------------------------------------------------------------------------
def excel_to_json(excel_path: str, json_path: str) -> None:
    if not os.path.isfile(excel_path):
        print(f"ERROR: Excel file not found → {excel_path}")
        sys.exit(1)

    wb = openpyxl.load_workbook(excel_path, data_only=True)
    ws = wb.active

    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        print("ERROR: Excel sheet is empty.")
        sys.exit(1)

    headers = [str(h).strip() if h is not None else "" for h in rows[0]]
    print(f"Detected {len(headers)} columns: {headers}")

    records = []
    for row_idx, row in enumerate(rows[1:], start=2):          # data starts at row 2
        # Skip completely blank rows
        if all(cell is None or str(cell).strip() == "" for cell in row):
            continue

        record = {}
        for col_idx, header in enumerate(headers):
            if not header:
                continue
            raw_value = row[col_idx] if col_idx < len(row) else None

            if raw_value is None or str(raw_value).strip() == "":
                record[header] = None
            elif header in NUMERIC_COLS:
                try:
                    # Preserve float vs int based on actual value
                    num = float(str(raw_value).replace(",", ""))
                    record[header] = int(num) if num.is_integer() else num
                except ValueError:
                    record[header] = raw_value
            else:
                record[header] = str(raw_value).strip()

        records.append(record)
        print(f"  Row {row_idx}: {record.get('testCaseId', '?')} — {record.get('description', '')}")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(records, f, indent=2, ensure_ascii=False)

    print(f"\n✅ Converted {len(records)} test cases → {json_path}")


if __name__ == "__main__":
    # Allow overriding paths via CLI args:  python converter.py input.xlsx output.json
    if len(sys.argv) == 3:
        EXCEL_FILE = sys.argv[1]
        JSON_FILE  = sys.argv[2]
    elif len(sys.argv) == 2:
        EXCEL_FILE = sys.argv[1]

    excel_to_json(EXCEL_FILE, JSON_FILE)
