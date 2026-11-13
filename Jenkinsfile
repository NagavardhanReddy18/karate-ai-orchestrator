pipeline {
    agent any

    parameters {
        choice(name: 'TARGET_ENV', choices: ['9190', 'dev', 'staging', 'local'], description: 'Target Beyond LO / CBS Environment')
        string(name: 'FEATURES', defaultValue: 'classpath:features/loans/04-BLO-LifeCycle.feature', description: 'Karate feature(s) or aliases (e.g. 04,05)')
        booleanParam(name: 'AUTO_HEAL', defaultValue: true, description: 'Enable autonomous CBS config self-healing')
        booleanParam(name: 'WRITE_EXCEL', defaultValue: true, description: 'Rewrite healed values back into Excel workbooks')
    }

    stages {
        stage('Run Karate Autonomous QA Agent') {
            steps {
                script {
                    if (isUnix()) {
                        sh """
                            chmod +x run-agent.sh
                            KARATE_ENV="${params.TARGET_ENV}" \
                            KARATE_FEATURES="${params.FEATURES}" \
                            KARATE_AGENT_HEAL="${params.AUTO_HEAL}" \
                            KARATE_AGENT_WRITE_EXCEL="${params.WRITE_EXCEL}" \
                            ./run-agent.sh
                        """
                    } else {
                        bat """
                            powershell -NoProfile -ExecutionPolicy Bypass -File run-agent.ps1 -Env "${params.TARGET_ENV}" -Features "${params.FEATURES}"
                        """
                    }
                }
            }
            post {
                always {
                    echo "=== Autonomous QA Self-Healing RCA Summary ==="
                    script {
                        if (fileExists('brain/reports/Autonomous_QA_Healing_Summary.txt')) {
                            echo readFile('brain/reports/Autonomous_QA_Healing_Summary.txt')
                        }
                    }
                    archiveArtifacts artifacts: 'brain/reports/**, brain/logs/**, target/karate-reports/**', allowEmptyArchive: true
                }
            }
        }
    }
}
