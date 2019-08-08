node {
    checkout scm
    def commonlib = load("pipeline-scripts/commonlib.groovy")

    // Expose properties for a parameterized build
    properties(
        [
            buildDiscarder(
                logRotator(
                    artifactDaysToKeepStr: '',
                    artifactNumToKeepStr: '',
                    daysToKeepStr: '',
                    numToKeepStr: '')),
            [
                $class: 'ParametersDefinitionProperty',
                parameterDefinitions: [
                    commonlib.ocpVersionParam('SYNC_VERSION'),
                    [
                        name: 'REPO_TYPE',
                        description: 'Type of repos to sync',
                        $class: 'hudson.model.ChoiceParameterDefinition',
                        choices: "unsigned\nsigned",
                        defaultValue: 'unsigned'
                    ],
                    commonlib.suppressEmailParam(),
                    [
                        name: 'MAIL_LIST_FAILURE',
                        description: 'Failure Mailing List',
                        $class: 'hudson.model.StringParameterDefinition',
                        defaultValue: [
                            'aos-art-automation+failed-reposync@redhat.com',
                        ].join(',')
                    ],
                    commonlib.mockParam(),
                ]
            ],
        ]
    )

    def buildlib = load("pipeline-scripts/buildlib.groovy")
    buildlib.initialize(false)

    currentBuild.displayName = "v${SYNC_VERSION} RepoSync"
    SYNC_DIR="/mnt/workspace/reposync"
    LOCAL_SYNC_DIR = "${SYNC_DIR}/${SYNC_VERSION}/"
    LOCAL_CACHE_DIR = "${SYNC_DIR}/cache/${SYNC_VERSION}/"

    MIRROR_TARGET = "use-mirror-upload.ops.rhcloud.com"
    MIRROR_PATH = "/srv/enterprise/reposync/${SYNC_VERSION}/"

    // doozer_working must be in WORKSPACE in order to have artifacts archived
    DOOZER_WORKING = "${WORKSPACE}/doozer_working"
    buildlib.cleanWorkdir(DOOZER_WORKING)

    try {
        sshagent(['openshift-bot']) {
            // To work on real repos, buildlib operations must run with the permissions of openshift-bot

            stage("sync repos to local") {
                command = "--working-dir ${DOOZER_WORKING} --group 'openshift-${SYNC_VERSION}' "
                command += "beta:reposync --output ${LOCAL_SYNC_DIR} --cachedir ${LOCAL_CACHE_DIR} --repo-type ${REPO_TYPE} "
		try {
                    buildlib.doozer command
		} catch (err) {
		    echo "whoops. fix this tomorrow please"
		}
            }

            stage("push to mirror") {
                sh "rsync -avzh --delete -e \"ssh -o StrictHostKeyChecking=no\" ${LOCAL_SYNC_DIR} ${MIRROR_TARGET}:${MIRROR_PATH} "
                mirror_result = buildlib.invoke_on_use_mirror("push.enterprise.sh")
                if (mirror_result.contains("[FAILURE]")) {
                    echo mirror_result
                    error("Error running ${SYNC_VERSION} reposync push.enterprise.sh:\n${mirror_result}")
                }
            }
        }
    } catch (err) {
        commonlib.email(
            to: "${MAIL_LIST_FAILURE}",
            replyTo: "aos-team-art@redhat.com",
            from: "aos-art-automation@redhat.com",
            subject: "Error syncing v${SYNC_VERSION} repos",
            body: """Encountered an error while running OCP pipeline: ${err}

Jenkins job: ${env.BUILD_URL}
        """);

        currentBuild.result = "FAILURE"
        throw err
    } finally {
        commonlib.safeArchiveArtifacts(["doozer_working/*.log"])
    }
}
