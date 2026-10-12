boolean call(String deploymentBranch) {
    def current = env.BRANCH_NAME ?: env.GIT_BRANCH ?: ''
    current = current.replaceFirst(/^origin\//, '')
    return current == deploymentBranch
}