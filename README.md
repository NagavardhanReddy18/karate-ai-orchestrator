# 🚀 Beyond LO — Karate AI Test Orchestrator & Triage (n8n)

An intelligent, AI-powered Test Automation Orchestrator and Triage Platform for the **Beyond LO (Loan Origination) Karate API Framework**.

Combines **n8n workflow automation**, **Karate API test suites**, and **LLM-driven Failure Triage** with automated reporting and **MantisBT defect logging**.

---

## 🌟 Key Features

1. **AI-Powered Root-Cause Triage**:
   - Automatically analyzes failed Karate steps, HTTP status codes (500, 503, 400), and stack traces.
   - Categorizes failures into:
     - `ENVIRONMENT_OR_DOWNSTREAM_ISSUE` (e.g. Core Banking CBS 503, database timeout).
     - `CODE_REGRESSION` (e.g. backend NullPointerException, schema mismatch).
     - `TEST_DATA_MISMATCH` (e.g. unmapped subproduct, invalid customer).
   - Generates instant actionable resolution steps for developers and QA.
2. **MantisBT Automatic Bug Logging**:
   - If a failure is diagnosed as a real application bug (`CODE_REGRESSION`), automatically logs a defect ticket in MantisBT via REST API.
3. **Slack / Teams ChatOps**:
   - Trigger runs on-demand from Slack (`/test 04 test`) and receive real-time execution cards with CBS account numbers.
4. **Automated Executive Reporting**:
   - Direct download links for `Karate_Test_Execution_Report.xlsx` and `karate-summary.html`.

---

## 🏗️ Architecture

```
[ Slack / Webhook / Git PR / Schedule ]
                  │
                  ▼
         ┌──────────────────┐
         │   n8n Workflow   │  (Port 5678)
         └────────┬─────────┘
                  │ 1. POST /api/tests/run
                  ▼
 ┌───────────────────────────────────┐
 │   Karate AI Orchestrator Bridge   │  (Port 5050 - server.js)
 └────────────────┬──────────────────┘
                  │ 2. Runs: mvn test -Dkarate.features=04,05...
                  ▼
 ┌───────────────────────────────────┐
 │   Beyond LO Karate Maven Suite    │  (beyond-lo-tests)
 └────────────────┬──────────────────┘
                  │ 3. Returns execution results & CBS accounts
                  ▼
 ┌───────────────────────────────────┐
 │   AI Failure Triage Engine        │  (ai-triage-engine.js)
 └────────────────┬──────────────────┘
                  │ 4. Categorizes failure & suggests fix
                  ▼
         ┌──────────────────┐
         │   n8n Workflow   │
         └────────┬─────────┘
                  │ 5. Dispatches notifications & defect logging
                  ▼
    ┌───────────────────────────┬───────────────────────────┐
    │                           │                           │
    ▼                           ▼                           ▼
[ Slack / Teams Card ]    [ MantisBT Bug Logged ]   [ Excel Report .xlsx ]
```

---

## 📂 Project Structure

```
karate-ai-orchestrator/
├── server.js                               # REST API Bridge connecting n8n to Maven/Karate
├── ai-triage-engine.js                     # Root-cause analysis engine (Gemini/OpenAI/Heuristic)
├── package.json                            # Node.js dependencies
├── .env                                    # Active configuration file
├── .env.example                            # Configuration template
├── docker-compose.yml                      # Optional Docker Compose setup for n8n
├── workflows/                              # Importable n8n Workflows
│   ├── 01_karate_ai_test_orchestrator.json # Main workflow: Webhook -> Run -> AI Triage -> Alert
│   ├── 02_slack_chatops_trigger.json       # Slack Slash Command (/test 04 test)
│   └── 03_mantis_auto_defect_logger.json   # MantisBT REST API bug logger
└── test/
    └── sample-failure-payload.json         # Sample test failure payload
```

---

## ⚡ Quick Start Guide (3 Simple Steps)

### Step 1: Configure Environment (.env)
Check `karate-ai-orchestrator/.env` and adjust the paths/tokens if needed:
```bash
PORT=5050
KARATE_PROJECT_PATH=C:/Latest-BeyondLo-Sep23rd/beyond-lo/beyond-lo-tests
DEFAULT_KARATE_ENV=test

# MantisBT Configuration
MANTIS_BASE_URL=http://your-mantis-host/api/rest
MANTIS_API_TOKEN=your_mantis_token_here
MANTIS_PROJECT_NAME=BeyondLO

# AI Provider (Optional: Heuristic fallback works offline with 0 setup!)
AI_PROVIDER=gemini
GEMINI_API_KEY=your_key_here
```

### Step 2: Start the Orchestrator Bridge
In this folder, start the bridge service:
```bash
npm start
```
You should see:
```
================================================================
  KARATE AI QA ORCHESTRATOR BRIDGE ACTIVE
  Listening on : http://localhost:5050
  Health Check : http://localhost:5050/api/health
  Test Runner  : POST http://localhost:5050/api/tests/run
  Karate Tests : C:/Latest-BeyondLo-Sep23rd/beyond-lo/beyond-lo-tests
================================================================
```

### Step 3: Start n8n & Import Workflows
You can run n8n in two ways:

#### Option A: Run directly with npx (Simplest on Windows)
```bash
npx n8n
```
Open **`http://localhost:5678`** in your browser.

#### Option B: Run via Docker Compose
```bash
docker compose up -d
```

#### Importing Workflows into n8n:
1. In n8n, click **"Add Workflow"** (top right).
2. Click the **three dots menu (`...`)** ➔ **"Import from File"**.
3. Select any of the files in `workflows/`:
   * `01_karate_ai_test_orchestrator.json`
   * `02_slack_chatops_trigger.json`
   * `03_mantis_auto_defect_logger.json`
4. Click **"Save"** and toggle the workflow to **"Active"**.

---

## 🧪 Testing the API Endpoints Directly (via curl / Postman)

### 1. Trigger Karate Feature 04 (Retail Loans)
```bash
curl -X POST http://localhost:5050/api/tests/run \
  -H "Content-Type: application/json" \
  -d '{"feature": "04", "env": "test"}'
```

### 2. Trigger Overdraft Features 06 and 07
```bash
curl -X POST http://localhost:5050/api/tests/run \
  -H "Content-Type: application/json" \
  -d '{"feature": "06,07", "env": "test"}'
```

### 3. Test AI Triage Engine Independently
```bash
curl -X POST http://localhost:5050/api/triage \
  -H "Content-Type: application/json" \
  -d '{
    "feature": "07",
    "errorLog": "POST /currentsavings HTTP 503 {\"error\":\"Matching sub-product not found. Account could not be opened\"}"
  }'
```

### 4. Download Latest Execution Excel Report
Open in browser or run:
```
http://localhost:5050/api/reports/download/excel
```

---

## 🐞 MantisBT Integration & Defect Logging

The orchestrator integrates directly with **MantisBT REST API** (`POST /api/rest/issues`) to automatically file defect tickets when Karate API regressions occur:

### How it Works:
1. When a test run fails, the AI Triage engine checks if the root cause is a code defect / regression (`CODE_REGRESSION`).
2. The orchestrator maps the severity:
   - `CRITICAL` ➔ Mantis `crash` / `block` (Priority: `urgent`)
   - `HIGH` ➔ Mantis `major` (Priority: `high`)
   - `MEDIUM` ➔ Mantis `minor` (Priority: `normal`)
   - `LOW` ➔ Mantis `trivial` (Priority: `low`)
3. A rich description is formatted containing reproduction steps, endpoint, HTTP status, AI root cause, CBS account details, and links to Excel reports.
4. If `MANTIS_BASE_URL` or `MANTIS_API_TOKEN` is not yet configured, the system operates in **Simulation Mode** (mocking issue creation with realistic IDs like `#0002093`) so you can test end-to-end without breaking anything.

### Test Mantis Logging Locally:
```bash
node test/test-mantis-logging.js
```

### File Defect Ticket Manually via REST API:
```bash
curl -X POST http://localhost:5050/api/defects/mantis \
  -H "Content-Type: application/json" \
  -d '{
    "feature": "06",
    "env": "test",
    "triage": {
      "severity": "CRITICAL",
      "failingEndpoint": "POST /api/v1/loan/disburse",
      "rootCauseSummary": "Core Banking CBS returned 503 Service Unavailable",
      "recommendedAction": "Verify CBS stub service on port 9190"
    }
  }'
```

