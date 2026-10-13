pipeline {
    agent any
    options {
        disableConcurrentBuilds(abortPrevious: true)
        timeout(time: 15, unit: 'MINUTES')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    stages {
        stage('Validate Repository') {
            failFast true
            parallel {
                stage('Lint and Test Pipeline Scripts') {
                    steps {
                        sh(label: 'Build test image and run shellcheck, structure checks and deploy script tests', script: '''
                            docker build -f tests/Dockerfile -t "jensonflare-library-tests:${BUILD_TAG}" .
                            docker run --rm "jensonflare-library-tests:${BUILD_TAG}"
                        ''')
                    }
                }
                stage('Compile Pipeline Steps') {
                    steps {
                        sh(label: 'Compile all pipeline steps in vars/', script: 'docker build -f tests/Dockerfile.groovy -t "jensonflare-library-groovy:${BUILD_TAG}" .')
                    }
                }
            }
        }
    }
    post {
        always {
            sh(label: 'Remove temporary test images', script: 'docker rmi "jensonflare-library-tests:${BUILD_TAG}" "jensonflare-library-groovy:${BUILD_TAG}" >/dev/null 2>&1 || true')
        }
    }
}