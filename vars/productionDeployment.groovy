def call(Map cfg) {
    def bundleDir = "${pwd(tmp: true)}/deploy-bundle"
    sh "rm -rf '${bundleDir}' && mkdir -p '${bundleDir}'"

    writeFile file: "${bundleDir}/deploy.sh", text: libraryResource('scripts/deploy.sh')
    writeFile file: "${bundleDir}/prune-images.sh", text: libraryResource('scripts/prune-images.sh')

    def hasProjectCompose = fileExists('docker/production/docker-compose.yaml')

    if (hasProjectCompose) {
        sh "cp docker/production/docker-compose.yaml '${bundleDir}/compose.base.yaml'"
    }

    if (fileExists('docker-compose.override.yaml')) {
        sh "cp docker-compose.override.yaml '${bundleDir}/docker-compose.override.yaml'"
    }

    def deployParams = [
        APP_DIR            : cfg.appDir,
        IMAGE              : cfg.image,
        NEW_TAG            : env.IMAGE_TAG,
        HEALTH_URL         : cfg.healthUrl ?: '',
        KEEP_TAGS          : cfg.keepRemoteTags,
        WAIT_TIMEOUT       : cfg.waitTimeout,
        PULL_SERVICES      : cfg.pullServices.join(' '),
        IMAGE_SERVICES     : cfg.imageServices.join(' '),
        DEPENDENCY_SERVICES: (cfg.dependencyServices ?: []).join(' '),
    ]
    
    if (cfg.backupService) {
        deployParams.BACKUP_SERVICE = cfg.backupService
        deployParams.BACKUP_KEEP    = cfg.backupKeep
    }
    
    if (cfg.containsKey('migrateCmd')) { 
        deployParams.MIGRATE_CMD = cfg.migrateCmd ?: '' 
    }
    
    if (cfg.migrateService) { 
        deployParams.MIGRATE_SERVICE = cfg.migrateService 
    }

    def paramsContent = ''

    for (param in deployParams) { 
        paramsContent += "${param.key}='${param.value}'\n" 
    }

    writeFile file: "${bundleDir}/deploy.params", text: paramsContent

    withCredentials([
        usernamePassword(credentialsId: cfg.githubCredentialsId, usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT'),
        string(credentialsId: cfg.prodUserCredentialsId, variable: 'PROD_USER'),
        string(credentialsId: cfg.prodHostCredentialsId, variable: 'PROD_HOST'),
    ]) {
        sshagent([cfg.sshCredentialsId]) {
            withEnv(["BUNDLE_DIR=${bundleDir}", "APP_DIR=${cfg.appDir}", "REMOTE_REGISTRY_LOGIN=${cfg.remoteRegistryLogin}",
                     "HAS_PROJECT_COMPOSE=${hasProjectCompose}", "PIPELINE_REPO=${cfg.pipelineRepo}",
                     "RESTRICTED_SSH=${cfg.restrictedSsh}", "TECH_STACK=${cfg.techStack}", "TEMPLATE_REF=${cfg.templateRef}"]) {
                sh(label: 'Send bundle and deploy (automatic rollback on failure)', script: '''
                    set -eu
                    set +x
                    SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15"
                    REMOTE="$PROD_USER@$PROD_HOST"

                    if [ "$HAS_PROJECT_COMPOSE" != "true" ]; then
                        curl -fsS --retry 3 -H "Authorization: Bearer $GH_PAT" \\
                          -o "$BUNDLE_DIR/compose.base.yaml" \\
                          "https://raw.githubusercontent.com/$PIPELINE_REPO/$TEMPLATE_REF/production/$TECH_STACK/docker-compose.yaml"
                    fi
                    [ -s "$BUNDLE_DIR/compose.base.yaml" ] || { echo "compose.base.yaml is empty"; exit 1; }

                    chmod +x "$BUNDLE_DIR"/*.sh
                    [ "$REMOTE_REGISTRY_LOGIN" = "true" ] && printf "GHCR_USER='%s'\\n" "$GH_USER" >> "$BUNDLE_DIR/deploy.params"

                    send_token() { if [ "$REMOTE_REGISTRY_LOGIN" = "true" ]; then printf '%s\\n' "$GH_PAT"; else cat /dev/null; fi; }

                    if [ "$RESTRICTED_SSH" = "true" ]; then
                        # Kunci SSH dibatasi forced command (remote-guard.sh): hanya "upload" dan "run".
                        tar -C "$BUNDLE_DIR" -c . | ssh $SSH_OPTS "$REMOTE" upload
                        send_token | ssh $SSH_OPTS "$REMOTE" run
                    else
                        ssh $SSH_OPTS "$REMOTE" "mkdir -p '$APP_DIR/.release' && rm -rf '$APP_DIR/.release'/*"
                        scp $SSH_OPTS -q "$BUNDLE_DIR"/* "$REMOTE:$APP_DIR/.release/"
                        send_token | ssh $SSH_OPTS "$REMOTE" "bash '$APP_DIR/.release/deploy.sh'"
                    fi
                ''')
            }
        }
    }
}