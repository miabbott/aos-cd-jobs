@NonCPS
def processImages(lines) {
    def data = []
    lines.split().each { line ->
        // label, name, nvr, version
        def fields = line.split(',')
        if (fields[0]) {
            data.add([
                name: fields[1],
                nvr: fields[2],
                version: fields[3].replace("v", ""),
            ])
        }
    }
    return data
}


def retrieveBotToken() {
    def token = ""
    withCredentials([usernamePassword(credentialsId: 'quay_appregistry_omps_bot', usernameVariable: 'QUAY_USERNAME', passwordVariable: 'QUAY_PASSWORD')]) {
        def requestJson = """
        {
            "user": {
                "username": "${QUAY_USERNAME}",
                "password": "${QUAY_PASSWORD}"
            }
        }
        """
        retry(3) {
            def response = httpRequest(
                url: "https://quay.io/cnr/api/v1/users/login",
                httpMode: 'POST',
                contentType: 'APPLICATION_JSON',
                requestBody: requestJson,
                timeout: 60,
                validResponseCodes: "200:599",
            )
            if (response.status != 200) {
                sleep(5)
                error "Quay token request failed: ${response.status} ${response.content}"
            }
            token = readJSON(text: response.content).token
        }
    }
    return token
}


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
                    numToKeepStr: '')
            ),
            [
                $class: 'ParametersDefinitionProperty',
                parameterDefinitions: [
                    commonlib.ocpVersionParam('BUILD_VERSION', '4'),
                    string(
                        name: 'IMAGES',
                        description: '(Optional) List of images to limit selection (default all)',
                        defaultValue: ""
                    ),
                    [
                        name: 'STREAM',
                        description: 'OMPS appregistry',
                        $class: 'hudson.model.ChoiceParameterDefinition',
                        choices: ['dev', 'stage', 'prod'],
                        defaultValue: 'dev',
                    ],
                    string(
                        name: 'ADVISORY',
                        description: 'Should not be filled if STREAM is "dev"',
                        defaultValue: '',
                    ),
                    booleanParam(
                        name: 'FORCE_METADATA_BUILD',
                        defaultValue: false,
                        description: "Always attempt to build the operator metadata repo, even if there is nothing new to be built"
                    ),
                    booleanParam(
                        name: 'SKIP_PUSH',
                        defaultValue: false,
                        description: "Do not push operator metadata"
                    ),
                    commonlib.suppressEmailParam(),
                    string(
                        name: 'MAIL_LIST_FAILURE',
                        description: 'Failure Mailing List',
                        defaultValue: [
                            'aos-art-automation+failed-appregistry@redhat.com',
                        ].join(',')
                    ),
                    commonlib.mockParam(),
                ]
            ],
            disableConcurrentBuilds()
        ]
    )

    buildlib.initialize(false)

    def workDir = "${env.WORKSPACE}/workDir"
    buildlib.cleanWorkdir(workDir)

    currentBuild.description = "Collecting appregistry images for ${params.BUILD_VERSION}"
    currentBuild.displayName += " - ${params.BUILD_VERSION}"

    def skipPush = params.SKIP_PUSH

    try {
        def operatorData = []
        sshagent(["openshift-bot"]) {
            stage("fetch appregistry images") {
                def include = params.IMAGES.trim()
                if (include) {
                    include = "--images " + commonlib.cleanCommaList(include)
                }
                def lines = buildlib.doozer """
                    --working-dir ${workDir}
                    --group 'openshift-${params.BUILD_VERSION}'
                    ${include}
                    images:print
                    --label 'com.redhat.delivery.appregistry'
                    --short '{label},{name},{build},{version}'
                """, [capture: true]
                operatorData = processImages(lines)
                writeYaml file: "${workDir}/appreg.yaml", data: operatorData
                currentBuild.description = "appregistry images collected for ${params.BUILD_VERSION}."
            }
            stage("build metadata container") {
                def nvrs = operatorData.collect { item -> item.nvr }

                buildlib.doozer """
                    --working-dir ${workDir}
                    --group openshift-${params.BUILD_VERSION}
                    operator-metadata:build ${nvrs.join(' ')}
                    ${params.FORCE_METADATA_BUILD ? "-f" : ""}
                    --stream ${params.STREAM}
                """
            }
            stage("push metadata") {
                if (skipPush) {
                    currentBuild.description += "\nskipping metadata push."
                    return
                }
                if (!operatorData) {
                    currentBuild.description += "\nno operator metadata to push."
                    return
                }

                if (params.STREAM == 'dev') {
                    currentBuild.description += "\npushing operator metadata."
                    withCredentials([usernamePassword(credentialsId: 'quay_appregistry_omps_bot', usernameVariable: 'QUAY_USERNAME', passwordVariable: 'QUAY_PASSWORD')]) {
                        def errors = []
                        def token = retrieveBotToken()
                        for (def i = 0; i < operatorData.size(); i++) {
                            def build = operatorData[i]
                            def metadata_nvr = buildlib.doozer("--group openshift-${params.BUILD_VERSION} operator-metadata:latest-build ${build.name}", [capture: true])

                            def response = [:]
                            try {
                                retry(errors ? 3 : 60) { // retry the first failing pkg for 30m; after that, give up after 1m30s
                                    response = [:] // ensure we aren't looking at a previous response
                                    response = httpRequest(
                                        url: "https://omps-prod.cloud.paas.psi.redhat.com/v2/redhat-operators-art/koji/${metadata_nvr}",
                                        httpMode: 'POST',
                                        customHeaders: [[name: 'Authorization', value: token]],
                                        timeout: 60,
                                        validResponseCodes: "200:599",
                                    )
                                    if (response.status != 200) {
                                        sleep(30)
                                        error "${[metadata_nvr: metadata_nvr, response_content: response.content]}"
                                    }
                                }
                            } catch (err) {
                                if (response.status != 200) {
                                    errors.add([
                                        metadata_nvr: metadata_nvr,
                                        response_status: response.status,
                                        response_content: response.content
                                    ])
                                } else {
                                    // failed because of something other than bad request; note that instead
                                    errors.add(err)
                                }
                                continue // without claiming any success
                            }
                            currentBuild.description += "\n  ${metadata_nvr}"
                        }
                        if (!errors.isEmpty()) {
                            error "${errors}"
                        }
                    }
                } else {
                    if (params.ADVISORY) {

                        // obtaining metadata NVRs of all builds
                        def build_names = []
                        operatorData.each { build -> build_names.add(build.name) }
                        doozer_cmd = "--group openshift-${params.BUILD_VERSION} operator-metadata:latest-build ${build_names.join(' ')}"
                        def metadata_nvrs = buildlib.doozer(doozer_cmd, [capture: true])

                        buildlib.elliott """--group openshift-${params.BUILD_VERSION}
                            change-state -s NEW_FILES
                            -a ${params.ADVISORY}
                            ${params.DRY_RUN ? "--noop" : ""}
                        """

                        def elliott_build_flags = []
                        metadata_nvrs.split("\n").each { nvr -> elliott_build_flags.add("--build ${nvr}") }

                        buildlib.elliott """--group openshift-${params.BUILD_VERSION}
                            find-builds -k image
                            ${elliott_build_flags.join(" ")}
                            --attach ${params.ADVISORY}
                        """

                        /*
                        // this would be convenient, except that we don't have a way
                        // to set the CDN repos first, and can't move to QE without that.
                        buildlib.elliott """--group openshift-${params.BUILD_VERSION}
                            change-state -s QE
                            -a ${params.ADVISORY}
                            ${params.DRY_RUN ? "--noop" : ""}
                        """
                        */
                    }
                }
            }
        }
    } catch (err) {
        currentBuild.description = "Job failed: ${err}\n-----------------\n${currentBuild.description}"
        if (skipPush) { return }  // don't spam on failures we don't care about
        commonlib.email(
            to: "${params.MAIL_LIST_FAILURE}",
            from: "aos-art-automation@redhat.com",
            replyTo: "aos-team-art@redhat.com",
            subject: "Unexpected error during appregistry job",
            body: "Console output: ${commonlib.buildURL('console')}\n${currentBuild.description}",
        )

        throw err
    } finally {
        commonlib.safeArchiveArtifacts([
            "workDir/*",
        ])
    }
}
