#!/usr/bin/env groovy

node {
    checkout scm
    def buildlib = load("pipeline-scripts/buildlib.groovy")
    def commonlib = buildlib.commonlib

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
                    [
                        name: 'FROM_RELEASE_TAG',
                        description: 'Release tag to pull tools from (e.g. 4.2.6 or 4.3.0-0.nightly-2019-11-13-233341)',
                        $class: 'hudson.model.StringParameterDefinition',
                        defaultValue: ""
                    ],
                    [
                        name: 'CLIENT_TYPE',
                        description: 'artifacts path under https://mirror.openshift.com',
                        $class: 'hudson.model.ChoiceParameterDefinition',
                        choices: [
                            "ocp",
                            "ocp-dev-preview",
                        ].join("\n"),
                        defaultValue: "ocp"
                    ],
                    [
                        name: 'MAIL_LIST_FAILURE',
                        description: 'Failure Mailing List',
                        $class: 'hudson.model.StringParameterDefinition',
                        defaultValue: [
                            'aos-art-automation+failed-oc-sync@redhat.com'
                        ].join(',')
                    ],
                    commonlib.suppressEmailParam(),
                    commonlib.mockParam(),
                ]
            ],
            disableConcurrentBuilds()
        ]
    )

    commonlib.checkMock()



    try {
        currentBuild.displayName = "#${currentBuild.number} - ${FROM_RELEASE_TAG} - ${CLIENT_TYPE}"

        if (params.CLIENT_TYPE == 'ocp') {
            if (params.FROM_RELEASE_TAG.contains('nightly')) {
                error("I'm not sure you want to publish a nightly out as the ocp client type")
            }
            pull_spec = "quay.io/openshift-release-dev/ocp-release:${params.FROM_RELEASE_TAG}"
        } else {
            pull_spec = "quay.io/openshift-release-dev/ocp-release-nightly:${params.FROM_RELEASE_TAG}"
        }

        sshagent(['aos-cd-test']) {
            stage("sync ocp clients") {
                // must be able to access remote registry to extract image contents
                buildlib.registry_quay_dev_login()
                commonlib.shell "./publish-clients-from-payload.sh ${env.WORKSPACE} ${FROM_RELEASE_TAG} ${CLIENT_TYPE} '${pull_spec}'"
            }
        }
    } catch (err) {
        def buildURL = env.BUILD_URL.replace('https://buildvm.openshift.eng.bos.redhat.com:8443', 'https://localhost:8888')
        commonlib.email(
            to: "${params.MAIL_LIST_FAILURE}",
            from: "aos-art-automation@redhat.com",
            replyTo: "aos-team-art@redhat.com",
            subject: "Error syncing ocp client from payload",
            body: """Encountered an error while syncing ocp client from payload: ${err}

Jenkins Job: ${buildURL}

""");
        currentBuild.description = "Error while syncing ocp client from payload:\n${err}"
        currentBuild.result = "FAILURE"
        throw err
    }
    buildlib.cleanWorkdir("${env.WORKSPACE}")
}
