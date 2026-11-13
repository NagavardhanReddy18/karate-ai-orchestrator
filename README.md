# Karate Autonomous QA Agent

Self-contained, CI/CD-ready Karate + Excel automation package with **Autonomous CBS Configuration Self-Healing**, local **`brain/`** storage, and full **First-Time Failure Reason $\rightarrow$ Rewrite $\rightarrow$ Resolution** reporting.

---

## Folder Structure

```text
karate-Autonomous-QA-Agent/
├── config/
│   └── agent-config.properties     <-- Configure JDK, JVM, Maven, Brain folder, Environment & Flags
├── brain/
│   ├── backups/                    <-- Clean baseline copies of all 17 Excel workbooks
│   ├── reports/                    <-- Generated RCA & Execution reports (JSON, TXT, HTML, XLSX)
│   ├── logs/                       <-- Timestamped execution logs
│   └── tools/                      <-- Standalone offline/diagnostic utilities
├── run-agent.ps1                   <-- Windows PowerShell launcher
├── run-agent.bat                   <-- Windows CMD/Jenkins batch launcher
├── run-agent.sh                    <-- Linux/macOS/Jenkins shell launcher
└── Jenkinsfile                     <-- Post-build Jenkins pipeline definition
```

---

## 1. Configure Paths (`config/agent-config.properties`)

Edit [`config/agent-config.properties`](config/agent-config.properties) for your server or Jenkins agent:

```properties
jdk.home=C:/Program Files/Java/jdk-17.0.0.1
jvm.options=-Xms512m -Xmx2048m -Dfile.encoding=UTF-8
maven.cmd=mvn
agent.brain.dir=./brain
karate.env=9190
karate.features=classpath:features/loans/04-BLO-LifeCycle.feature
karate.agent.heal=true
karate.agent.writeExcel=true
```

---

## 2. Run Locally or on Server

### Windows (PowerShell / CMD)
```powershell
.\run-agent.ps1
# or:
.\run-agent.bat
```

### Linux / Jenkins
```bash
chmod +x run-agent.sh
./run-agent.sh
```

### Restore Baseline Excel Files From Local Brain Backup
```powershell
.\run-agent.ps1 -RestoreBackup
```

---

## 3. Where to Check Self-Healing Reports

All reports are written to **`brain/reports/`** (and mirrored in `target/karate-reports/`):
- `brain/reports/Autonomous_QA_Healing_Summary.txt` — Human-readable summary showing:
  1. **First-Time Failure Reason** (exact CBS sub-product constraint violated by the old Excel data)
  2. **Rewrite Applied** (`Field: Old -> New` in `.xlsx`)
  3. **Final Resolution Status** (`RESOLVED — Test PASSED after rewrite (CBS Account: ...)`)
- `brain/reports/cbs-agent-healing-report.json` — Machine-readable audit log
- `brain/reports/Karate_Test_Execution_Report.xlsx` — Multi-sheet Excel workbook including **Autonomous Self-Healing RCA**
- `brain/reports/karate-build-summary.html` & `karate-build-summary.txt` — Jenkins build & email summaries
