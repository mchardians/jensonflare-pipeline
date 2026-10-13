def call(Map args = [:]) {
    def techStack = args.techStack ?: 'laravel'

    if (!(techStack ==~ /^[a-z0-9][a-z0-9-]*$/)) { 
        error "standardPipeline: techStack name is invalid: '${techStack}'" 
    }

    def techStackConfig = new groovy.json.JsonSlurperClassic().parseText(libraryResource("techstacks/${techStack}.json"))

    def cfg = [
        image : env.SIPP_BASE_IMAGE,
        appDir : env.PROD_APP_DIR,
        deploymentBranch : 'main',
        healthUrl : '',
        bakeFile : '',
        bakeResource : techStackConfig.bakeResource,
        bakeTarget : techStackConfig.bakeTarget ?: 'ci',
        testImage : techStackConfig.test?.image ?: '',
        testLabel : techStackConfig.test?.label ?: 'Tests',
        testEnv : techStackConfig.test?.env ?: [:],
        dependencyServices : techStackConfig.dependencyServices ?: [],
        migrateService : techStackConfig.migrateService ?: '',
        migrateCmd : techStackConfig.migrateCmd ?: '',
        sonarTool : env.SONARQUBE_TOOLS,
        sonarServer : env.SONARQUBE_SERVER,
        sonarGateTimeoutMin : 5,
        securityServices : techStackConfig.securityServices,
        securitySeverity : 'HIGH,CRITICAL',
        securityImage : 'aquasec/trivy:latest',
        githubOwner : env.GITHUB_USER,
        githubRepo : env.GITHUB_PROJECT,
        githubCredentialsId : 'github-credentials',
        sshCredentialsId : 'production-ssh-key',
        prodUserCredentialsId : 'production-user',
        prodHostCredentialsId : 'production-host',
        remoteRegistryLogin : true,
        keepLocalTags : 3,
        keepRemoteTags : 3,
        waitTimeout : 180,
        techStack : techStack,
        templateRef : 'main',
        pipelineRepo : "${env.GITHUB_USER ?: 'OWNER'}/jensonflare-pipeline",
        restrictedSsh : false,
        backupService : techStackConfig.backupService ?: '',
        backupKeep : 5,
        pullServices : techStackConfig.pullServices,
        imageServices : techStackConfig.imageServices,
        timeoutMinutes : 45,
    ] + args

    validatePipelineConfig(cfg)

    echo "Tech stack: ${techStack} (image services: ${cfg.imageServices.join(', ')})"

    pipeline {
        agent any

        options {
            disableConcurrentBuilds()
            timeout(time: cfg.timeoutMinutes, unit: 'MINUTES')
            timestamps()
            buildDiscarder(logRotator(numToKeepStr: '20'))
        }

        stages {
            stage('Prepare') {
                steps {
                    script {
                        deploymentStatus(cfg, 'pending', 'Pipeline started')

                        sh(label: 'Preflight: check the Docker daemon and the buildx plugin', script: '''
                            docker version --format '{{.Server.Version}}' >/dev/null
                            docker buildx version >/dev/null || {
                                echo "docker buildx is not available in Jenkins (mount the cli-plugins directory, see ci/docker-compose.yaml)"; exit 1; }
                        ''')

                        def semanticVersion = sh(label: 'Read the semantic version from the VERSION file (default 1.0.0)', script: 'cat VERSION 2>/dev/null || echo 1.0.0', returnStdout: true).trim()
                        def commitSha = (env.GIT_COMMIT ?: 'nogit').take(7)
                        env.IMAGE_TAG = "v${semanticVersion}-${env.BUILD_NUMBER}-${commitSha}"
                        echo "Image tag: ${env.IMAGE_TAG}"
                    }
                }
            }

            stage('Build images') {
                steps {
                    script {
                        def bakeFile = cfg.bakeFile
                        if (!bakeFile) {
                            bakeFile = "${pwd(tmp: true)}/${cfg.techStack}.hcl"
                            echo "Bake definition: ${cfg.bakeResource} (from the pipeline library)"
                            writeFile file: bakeFile, text: libraryResource(cfg.bakeResource)
                        }
                        withEnv(["BAKE_FILE=${bakeFile}", "BAKE_TARGET=${cfg.bakeTarget}", "IMAGE=${cfg.image}", "TAG=${env.IMAGE_TAG}"]) {
                            sh(label: "buildx bake: ${cfg.imageServices.join(', ')} (parallel, shared cache)",
                               script: 'docker buildx bake -f "$BAKE_FILE" --load --provenance=false --progress=plain "$BAKE_TARGET"')
                        }
                    }
                }
            }

            stage('Verify') {
                failFast true
                parallel {
                    stage('Tests') {
                        when { expression { cfg.testImage } }
                        steps {
                            script {
                                def envArgs = ''
                                for (variable in cfg.testEnv) { envArgs += " -e '${variable.key}=${variable.value}'" }
                                sh(label: cfg.testLabel, script: "docker run --rm${envArgs} ${cfg.testImage}:${env.IMAGE_TAG}")
                            }
                        }
                    }

                    stage('Static analysis') {
                        when { expression { cfg.sonarTool && cfg.sonarServer } }
                        stages {
                            stage('Sonar scan') {
                                steps {
                                    script {
                                        def scannerHome = tool(cfg.sonarTool)
                                        withSonarQubeEnv(cfg.sonarServer) {
                                            sh(label: 'SonarQube scanner', script: "${scannerHome}/bin/sonar-scanner")
                                        }
                                    }
                                }
                            }
                            stage('Quality gate') {
                                steps {
                                    timeout(time: cfg.sonarGateTimeoutMin, unit: 'MINUTES') {
                                        script {
                                            def qualityGate = waitForQualityGate()
                                            if (qualityGate.status != 'OK') {
                                                error "SonarQube Quality Gate failed: ${qualityGate.status}"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    stage('Security analysis') {
                        steps {
                            script {
                                def images = []
                                for (service in cfg.securityServices) { images << "${cfg.image}-${service}:${env.IMAGE_TAG}" }
                                securityAnalysis(images: images, severity: cfg.securitySeverity, securityImage: cfg.securityImage)
                            }
                        }
                    }
                }
            }

            stage('Push images') {
                when { expression { deploymentBranch(cfg.deploymentBranch) } }
                steps {
                    retry(2) {
                        withCredentials([usernamePassword(credentialsId: cfg.githubCredentialsId, usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT')]) {
                            withEnv(["IMAGE=${cfg.image}", "TAG=${env.IMAGE_TAG}", "IMAGE_SERVICES=${cfg.imageServices.join(' ')}"]) {
                                sh(label: 'Push images to GHCR', script: '''
                                    set +x
                                    export DOCKER_CONFIG="$(mktemp -d)"
                                    trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                                    echo "$GH_PAT" | docker login ghcr.io -u "$GH_USER" --password-stdin
                                    for service in $IMAGE_SERVICES; do
                                        docker push "${IMAGE}-${service}:${TAG}"
                                        docker push "${IMAGE}-${service}:latest"
                                    done
                                ''')
                            }
                        }
                    }
                }
            }

            stage('Deploy') {
                when { expression { deploymentBranch(cfg.deploymentBranch) } }
                steps {
                    productionDeployment(cfg)
                }
            }
        }

        post {
            success { script { deploymentStatus(cfg, 'success', 'Pipeline passed successfully!') } }
            failure { script { deploymentStatus(cfg, 'failure', 'Pipeline failed.') } }
            aborted { script { deploymentStatus(cfg, 'error', 'Pipeline aborted.') } }
            always  { script { cleanupLocalImages(cfg) } }
        }
    }
}

def validatePipelineConfig(Map cfg) {
    if (!cfg.image || !(cfg.image ==~ /^[a-z0-9._\/:-]+$/)) {
        error "standardPipeline: 'image' is required and must be lowercase, e.g. ghcr.io/owner/app. Current value: '${cfg.image}'"
    }
    if (!cfg.appDir || !(cfg.appDir ==~ /^\/[A-Za-z0-9._\/-]+$/)) {
        error "standardPipeline: 'appDir' must be a simple absolute path. Current value: '${cfg.appDir}'"
    }
    if (cfg.healthUrl && !(cfg.healthUrl ==~ /^https?:\/\/[^\s']+$/)) {
        error "standardPipeline: 'healthUrl' is invalid: '${cfg.healthUrl}'"
    }
    if (!(cfg.techStack ==~ /^[a-z0-9][a-z0-9-]*$/)) {
        error "standardPipeline: 'techStack' is invalid: '${cfg.techStack}'"
    }
    if (!(cfg.templateRef ==~ /^[A-Za-z0-9._\/-]+$/)) {
        error "standardPipeline: 'templateRef' is invalid: '${cfg.templateRef}'"
    }
    if (!(cfg.pipelineRepo ==~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/)) {
        error "standardPipeline: 'pipelineRepo' must be 'owner/repo': '${cfg.pipelineRepo}'"
    }
    for (key in ['pullServices', 'imageServices']) {
        if (!(cfg[key] instanceof List) || !cfg[key] || !cfg[key].every { it ==~ /^[a-z0-9][a-z0-9_.-]*$/ }) {
            error "standardPipeline: '${key}' must be a non-empty list of simple service names: ${cfg[key]}"
        }
    }
    if (!(cfg.dependencyServices instanceof List) || !cfg.dependencyServices.every { it ==~ /^[a-z0-9][a-z0-9_.-]*$/ }) {
        error "standardPipeline: 'dependencyServices' must be a list of simple service names: ${cfg.dependencyServices}"
    }
    if (!(cfg.bakeResource ==~ /^[A-Za-z0-9._\/-]+$/) || !(cfg.bakeTarget ==~ /^[A-Za-z0-9._-]+$/)) {
        error "standardPipeline: 'bakeResource' or 'bakeTarget' is invalid"
    }
    if (cfg.testImage && !(cfg.testImage ==~ /^[a-z0-9._\/-]+$/)) {
        error "standardPipeline: 'testImage' is invalid: '${cfg.testImage}'"
    }
    if (cfg.backupService && !(cfg.backupService ==~ /^[a-z0-9][a-z0-9_.-]*$/)) {
        error "standardPipeline: 'backupService' is invalid: '${cfg.backupService}'"
    }
    if (!(cfg.backupKeep instanceof Integer) || cfg.backupKeep < 1) {
        error "standardPipeline: 'backupKeep' must be an integer >= 1"
    }
    if (cfg.migrateService && !(cfg.migrateService ==~ /^[a-z0-9][a-z0-9_.-]*$/)) {
        error "standardPipeline: 'migrateService' is invalid: '${cfg.migrateService}'"
    }
    if (cfg.migrateCmd && !(cfg.migrateCmd ==~ /^[A-Za-z0-9 _.:=\/-]+$/)) {
        error "standardPipeline: 'migrateCmd' may only contain simple characters: '${cfg.migrateCmd}'"
    }
    if (!(cfg.deploymentBranch ==~ /^[A-Za-z0-9._\/-]+$/)) {
        error "standardPipeline: 'deploymentBranch' is invalid: '${cfg.deploymentBranch}'"
    }
}

def cleanupLocalImages(Map cfg) {
    if (!env.IMAGE_TAG) { return }
    try {
        def pruneScript = "${pwd(tmp: true)}/prune-images.sh"
        writeFile file: pruneScript, text: libraryResource('scripts/prune-images.sh')
        withEnv(["PRUNE_SCRIPT=${pruneScript}", "IMAGE=${cfg.image}", "KEEP=${cfg.keepLocalTags}", "TAG=${env.IMAGE_TAG}",
                 "IMAGE_SERVICES=${cfg.imageServices.join(' ')}", "TEST_IMAGE=${cfg.testImage}"]) {
            sh(label: 'Local cleanup (keeps base images and recent layer cache)', script: '''
                [ -z "$TEST_IMAGE" ] || docker rmi "${TEST_IMAGE}:${TAG}" >/dev/null 2>&1 || true
                bash "$PRUNE_SCRIPT" "$IMAGE" "$KEEP" "$TAG" || true
                docker builder prune -f --filter "until=168h" >/dev/null 2>&1 || true
            ''')
        }
    } catch (err) {
        echo "Local cleanup skipped: ${err.message}"
    }
}