def call(Map cfg, String state, String description) {
    if (!cfg.githubOwner || !cfg.githubRepo || !env.GIT_COMMIT) {
        echo 'setGithubCommitStatus skipped (githubOwner / githubRepo / GIT_COMMIT is not available)'
        return
    }

    def statusFile = "${pwd(tmp: true)}/github-status.json"
    writeFile file: statusFile, text: groovy.json.JsonOutput.toJson([
        state      : state,
        target_url : env.BUILD_URL,
        description: description,
        context    : cfg.statusContext ?: 'Jenkins CI/CD',
    ])

    try {
        withCredentials([usernamePassword(credentialsId: cfg.githubCredentialsId,
                                          usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT')]) {
            withEnv(["STATUS_FILE=${statusFile}",
                     "STATUS_URL=https://api.github.com/repos/${cfg.githubOwner}/${cfg.githubRepo}/statuses/${env.GIT_COMMIT}"]) {
                sh(label: "GitHub commit status: ${state}", script: '''
                    set +x
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 -X POST \\
                        -H "Accept: application/vnd.github+json" \\
                        -H "Authorization: Bearer $GH_PAT" \\
                        -H "X-GitHub-Api-Version: 2022-11-28" \\
                        --data @"$STATUS_FILE" "$STATUS_URL") || true
                    echo "GitHub status API -> HTTP ${http_code:-000}"
                ''')
            }
        }
    } catch (err) {
        echo "setGithubCommitStatus failed (ignored): ${err.message}"
    }
}