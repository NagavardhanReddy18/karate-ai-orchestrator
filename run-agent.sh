#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AGENT_CONFIG_FILE:-$SCRIPT_DIR/config/agent-config.properties}"

get_prop() {
  local key="$1"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep -E "^[[:space:]]*${key}=" "$CONFIG_FILE" | tail -n1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  fi
}

JDK_HOME="${JAVA_HOME:-$(get_prop jdk.home)}"
JVM_OPTS="${MAVEN_OPTS:-$(get_prop jvm.options)}"
MVN_CMD="${MVN_CMD:-$(get_prop maven.cmd)}"
BRAIN_RAW="${AGENT_BRAIN_DIR:-$(get_prop agent.brain.dir)}"
ENV_TARGET="${KARATE_ENV:-$(get_prop karate.env)}"
FEATURES="${KARATE_FEATURES:-$(get_prop karate.features)}"
BASE_URL="${LO_TEST_BASE_URL:-$(get_prop lo.test.baseUrl)}"
HEAL_FLAG="${KARATE_AGENT_HEAL:-$(get_prop karate.agent.heal)}"
WRITE_FLAG="${KARATE_AGENT_WRITE_EXCEL:-$(get_prop karate.agent.writeExcel)}"

MVN_CMD="${MVN_CMD:-mvn}"
BRAIN_RAW="${BRAIN_RAW:-./brain}"
if [[ "$BRAIN_RAW" = /* ]]; then
  BRAIN_DIR="$BRAIN_RAW"
else
  BRAIN_DIR="$SCRIPT_DIR/${BRAIN_RAW#./}"
fi

if [[ -n "$JDK_HOME" && -d "$JDK_HOME" ]]; then
  export JAVA_HOME="$JDK_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
export MAVEN_OPTS="${JVM_OPTS:--Xms512m -Xmx2048m -Dfile.encoding=UTF-8}"

mkdir -p "$BRAIN_DIR/logs" "$BRAIN_DIR/reports" "$BRAIN_DIR/backups"
LOG_FILE="$BRAIN_DIR/logs/agent-run-$(date +%Y%m%d_%H%M%S).log"

ARGS=(
  "test"
  "-Dagent.config.file=$CONFIG_FILE"
  "-Dagent.brain.dir=$BRAIN_DIR"
  "-Dkarate.env=${ENV_TARGET:-9190}"
  "-Dkarate.agent.heal=${HEAL_FLAG:-true}"
  "-Dkarate.agent.writeExcel=${WRITE_FLAG:-true}"
)
[[ -n "$BASE_URL" ]] && ARGS+=("-Dlo.test.baseUrl=$BASE_URL")
[[ -n "$FEATURES" ]] && ARGS+=("-Dkarate.features=$FEATURES")

echo "========================================================================"
echo " KARATE AUTONOMOUS QA AGENT"
echo " JAVA_HOME  : ${JAVA_HOME:-system}"
echo " MAVEN_OPTS : $MAVEN_OPTS"
echo " Brain Dir  : $BRAIN_DIR"
echo " Target Env : ${ENV_TARGET:-9190}"
echo " Log File   : $LOG_FILE"
echo "========================================================================"

cd "$SCRIPT_DIR"
"$MVN_CMD" "${ARGS[@]}" 2>&1 | tee "$LOG_FILE"
