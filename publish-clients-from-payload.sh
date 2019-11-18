#!/bin/bash
set -eux
export MOBY_DISABLE_PIGZ=true
WORKSPACE=$1
VERSION=$2
CLIENT_TYPE=$3
PULL_SPEC=$4

ARCH=$(skopeo inspect docker://${PULL_SPEC} -config | jq .architecture -r)
if [[ "${ARCH}" == "amd64" ]]; then
    ARCH="x86_64"
fi

OC_MIRROR_DIR="/srv/pub/openshift-v4/${ARCH}/clients/${CLIENT_TYPE}"

SSH_OPTS="-l jenkins_aos_cd_bot -o StrictHostKeychecking=no use-mirror-upload.ops.rhcloud.com"

#check if already exists
if ssh ${SSH_OPTS} "[ -d ${OC_MIRROR_DIR}/${VERSION} ]";
then
    echo "Already have latest version"
    exit 0
else
    echo "Fetching OCP clients from payload ${VERSION}"
fi

TMPDIR=${WORKSPACE}/tools
mkdir -p "${TMPDIR}"
cd ${TMPDIR}

OUTDIR=${TMPDIR}/${VERSION}
mkdir -p ${OUTDIR}
pushd ${OUTDIR}

#extract all release assests
GOTRACEBACK=all oc version
GOTRACEBACK=all oc adm release extract --tools --command-os=* ${PULL_SPEC} --to=${OUTDIR}
popd

#sync to use-mirror-upload
rsync \
    -av --delete-after --progress --no-g --omit-dir-times --chmod=Dug=rwX \
    -e "ssh -l jenkins_aos_cd_bot -o StrictHostKeyChecking=no" \
    "${OUTDIR}" \
    use-mirror-upload.ops.rhcloud.com:${OC_MIRROR_DIR}/

retry() {
  local count exit_code
  count=0
  until "$@"; do
    exit_code="$?"
    count=$((count + 1))
    if [[ $count -lt 4 ]]; then
      sleep 5
    else
      return "$exit_code"
    fi
  done
}

# kick off full mirror push
retry ssh ${SSH_OPTS} timeout 15m /usr/local/bin/push.pub.sh "openshift-v4/${ARCH}/clients/${CLIENT_TYPE}/${VERSION}" -v
