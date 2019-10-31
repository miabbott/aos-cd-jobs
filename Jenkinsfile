@NonCPS
def parseAndFilterOperators(lines) {
    def data = []
    lines.split().each { line ->
        // label, name, nvr, version, component
        def fields = line.split(',')
        if (fields[0]) {
            data.add([
                name: fields[1],
                nvr: fields[2],
                version: fields[3].replace("v", ""),
                component: fields[4],
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
                        name: 'OLM_OPERATOR_ADVISORIES',
                        description: 'One or more advisories where OLM operators are attached\n* Required for "stage" and "prod" STREAMs',
                        defaultValue: '',
                    ),
                    string(
                        name: 'METADATA_ADVISORY',
                        description: 'Advisory to attach corresponding metadata builds\n* Required for "stage" and "prod" STREAMs',
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

    def buildVersion = params.BUILD_VERSION

    currentBuild.description = "Collecting appregistry images for ${buildVersion} (${params.STREAM} stream)"
    currentBuild.displayName += " - ${buildVersion} (${params.STREAM})"

    def skipPush = params.SKIP_PUSH

    def validate = { params ->
        if (params.STREAM in ["stage", "prod"]) {
            if (!params.OLM_OPERATOR_ADVISORIES || !params.METADATA_ADVISORY) {
                currentBuild.description += """\n
                ERROR: OLM_OPERATOR_ADVISORIES and METADATA_ADVISORY parameters are required for selected STREAM.
                """
                return false
            }
        }
        return true
    }

    def doozer = { cmd ->
        buildlib.doozer("--working-dir ${workDir} -g openshift-${buildVersion} ${cmd}", [capture: true])
    }

    def elliott = { cmd ->
        buildlib.elliott("-g openshift-${buildVersion} ${cmd}", [capture: true])
    }

    def getImagesData = { include ->
        if (include) {
            include = "--images " + commonlib.cleanCommaList(include)
        }
        doozer """
            ${include}
            images:print
            --label 'com.redhat.delivery.appregistry'
            --short '{label},{name},{build},{version},{component}'
        """
    }

    def fetchNVRsFromAdvisories = { advisories ->
        commonlib.cleanCommaList(advisories).split(",").collect { advisory ->
            readJSON(text: elliott("get --json - ${advisory}")).errata_builds.values().flatten()
        }.flatten()
    }

    def findImageNVRsInAdvisories = { images, advisoriesNVRs ->
        images.collect {
            image -> [
                name: image.name,
                nvr: advisoriesNVRs.find { it.startsWith(image.component) }
            ]
        }
    }

    def pushToOMPS = { token, metadata_nvr ->
        httpRequest(
            url: "https://omps-prod.cloud.paas.psi.redhat.com/v2/redhat-operators-art/koji/${metadata_nvr}",
            httpMode: 'POST',
            customHeaders: [[name: 'Authorization', value: token]],
            timeout: 60,
            validResponseCodes: "200:599",
        )
    }

    def getMetadataNVRs = { operatorNVRs, stream ->
        def nvrFlags = operatorNVRs.collect { "--nvr ${it}" }.join(" ")
        doozer("operator-metadata:latest-build --stream ${stream} ${nvrFlags}")
    }

    def attachToAdvisory = { advisory, metadata_nvrs ->
        def elliott_build_flags = []
        metadata_nvrs.split().each { nvr -> elliott_build_flags.add("--build ${nvr}") }

        elliott """
            find-builds -k image
            ${elliott_build_flags.join(" ")}
            --attach ${advisory}
        """
    }

    try {
        def operatorData = []
        sshagent(["openshift-bot"]) {
            stage("validate params") {
                if (!validate(params)) {
                    error "Parameter validation failed"
                }
            }
            stage("fetch appregistry images") {
                def lines = getImagesData(params.IMAGES.trim())
                operatorData = parseAndFilterOperators(lines)

                if (params.STREAM in ["stage", "prod"]) {
                    def advisoriesNVRs = fetchNVRsFromAdvisories(params.OLM_OPERATOR_ADVISORIES)
                    operatorData = findImageNVRsInAdvisories(operatorData, advisoriesNVRs)

                    if (operatorData.any { it.nvr == null }) {
                        currentBuild.description += """\n
                        Advisories missing operators ${operatorData.findAll { it.nvr }.collect { it.name }.join(",")}
                        """
                        echo """
                        ERROR: The following operators were not found in provided advisories.
                        ${operatorData.findAll { !it.nvr }.collect { it.name }.join(",")}

                        Possible solutions:
                        1. Add more advisories in OLM_OPERATOR_ADVISORIES parameter, that have the missing operators attached
                        2. Attach missing operators to at least one of the provided advisories: ${params.OLM_OPERATOR_ADVISORIES}
                        3. Limit the expected operators in IMAGES parameter: ${operatorData.findAll { it.nvr }.collect { it.name }.join(",")}
                        """
                        error "operators not found"
                    }
                }

                writeYaml file: "${workDir}/appreg.yaml", data: operatorData
                currentBuild.description = "appregistry images collected for ${buildVersion}."
            }
            stage("build metadata container") {
                def nvrs = operatorData.collect { item -> item.nvr }

                doozer """
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
                            def metadata_nvr = getMetadataNVRs([build.nvr], params.STREAM)

                            def response = [:]
                            try {
                                retry(errors ? 3 : 60) { // retry the first failing pkg for 30m; after that, give up after 1m30s
                                    response = [:] // ensure we aren't looking at a previous response
                                    response = pushToOMPS(token, metadata_nvr)
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
                }
            }
            stage("attach metadata to advisory") {
                    if (!params.METADATA_ADVISORY) {
                        currentBuild.description += "\nskipping attach to advisory."
                        return
                    }

                    def metadata_nvrs = getMetadataNVRs(operatorData.collect { it.nvr }, params.STREAM)

                    elliott """
                        change-state -s NEW_FILES
                        -a ${params.METADATA_ADVISORY}
                        ${params.DRY_RUN ? "--noop" : ""}
                    """

                    attachToAdvisory(params.METADATA_ADVISORY, metadata_nvrs)

                    /*
                    // this would be convenient, except that we don't have a way
                    // to set the CDN repos first, and can't move to QE without that.
                    elliott """
                        change-state -s QE
                        -a ${params.METADATA_ADVISORY}
                        ${params.DRY_RUN ? "--noop" : ""}
                    """
                    */
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
