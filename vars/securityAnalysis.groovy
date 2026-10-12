def call(Map options = [:]) {
    def images = options.images ?: []
    def severity = options.severity ?: 'HIGH,CRITICAL'
    def securityImage = options.securityImage ?: 'aquasec/trivy:latest'
    if (!images) { error 'securityAnalysis: the images list is empty' }

    withEnv(["TRIVY_IMAGE=${securityImage}", "TRIVY_SEVERITY=${severity}"]) {
        retry(3) {
            sh(label: 'Trivy: update vulnerability database (cache volume)', script: '''
                docker run --rm -v trivy-cache:/root/.cache "$TRIVY_IMAGE" image --download-db-only --no-progress
            ''')
        }
        
        for (imageName in images) {
            withEnv(["SCAN_IMAGE=${imageName}"]) {
                def exitCode = sh(label: "Trivy: scan ${imageName}", returnStatus: true, script: '''
                    docker run --rm \\
                        -v /var/run/docker.sock:/var/run/docker.sock \\
                        -v trivy-cache:/root/.cache \\
                        "$TRIVY_IMAGE" image --skip-db-update --no-progress --ignore-unfixed \\
                        --severity "$TRIVY_SEVERITY" --exit-code 1 "$SCAN_IMAGE"
                ''')
                if (exitCode != 0) {
                    error "Trivy found ${severity} vulnerabilities in ${imageName} (see the log above)."
                }
            }
        }
    }
}