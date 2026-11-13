// VProfile CI pipeline: build -> unit tests -> Checkstyle -> SonarQube analysis -> Quality Gate -> publish to Nexus
pipeline {
  agent any
  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
    disableConcurrentBuilds()
  }
  environment {
    NEXUS_URL  = 'nexus:8081'        // compose service name (use the server's IP/DNS in a real setup)
    NEXUS_REPO = 'vprofile-repo'
  }
  stages {
    stage('Build') {
      steps { sh 'mvn -B install -DskipTests' }
      post { success { archiveArtifacts artifacts: '**/target/*.war', fingerprint: true } }
    }
    stage('Unit Tests') {
      steps { sh 'mvn -B test jacoco:report' }   // jacoco:report writes target/site/jacoco/jacoco.xml for Sonar
      post { always { junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml' } }
    }
    stage('Checkstyle') {
      steps { sh 'mvn -B checkstyle:checkstyle' }
    }
    stage('SonarQube Analysis') {
      environment { scannerHome = tool 'sonarscanner' }
      steps {
        withSonarQubeEnv('sonarserver') {
          sh '''${scannerHome}/bin/sonar-scanner \
            -Dsonar.projectKey=vprofile -Dsonar.projectName=vprofile -Dsonar.projectVersion=${BUILD_ID} \
            -Dsonar.sources=src/ -Dsonar.java.binaries=target/classes \
            -Dsonar.junit.reportsPath=target/surefire-reports \
            -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml \
            -Dsonar.java.checkstyle.reportPaths=target/checkstyle-result.xml'''
        }
      }
    }
    stage('Quality Gate') {
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true   // SonarQube calls back via webhook; a failing gate stops here
        }
      }
    }
    stage('Publish to Nexus') {
      steps {
        nexusArtifactUploader(
          nexusVersion: 'nexus3', protocol: 'http', nexusUrl: "${NEXUS_URL}",
          groupId: 'QA', version: "${env.BUILD_ID}-${env.GIT_COMMIT.take(7)}",   // traceable: build number + commit
          repository: "${NEXUS_REPO}", credentialsId: 'nexuslogin',
          artifacts: [[artifactId: 'vproapp', classifier: '', file: 'target/vprofile-v2.war', type: 'war']]
        )
      }
    }
  }
  post {
    success { echo "Build ${env.BUILD_ID} passed: artifact vproapp-${env.BUILD_ID}-${env.GIT_COMMIT.take(7)}.war is in Nexus" }
    failure { echo "Build ${env.BUILD_ID} failed: check the first red stage" }
  }
}
