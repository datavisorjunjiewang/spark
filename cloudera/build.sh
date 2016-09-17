#!/bin/bash -e
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# We shouldn't be skipping the build by default
SKIP_BUILD=false
SPARK_HOME="$(cd "$(dirname "$0")"/..; pwd)"
# Let's parse out the pom file to get the version of Spark2 being built
VERSION=$(cd $SPARK_HOME; build/mvn help:evaluate -Dexpression=project.version \
          -Dcdh.build=true -pl :spark-parent_2.11 2>/dev/null | \
          grep -v "INFO" | tail -n 1)

if [[ "$VERSION" != 2* ]]; then
  echo "Detected version (version=$VERSION) does not start with 2"
  exit 1
fi

# Commitish from github.mtv.cloudera.com/CDH/cdh.git repo
# Taken from a point in time from cdh6.x branch of cdh.git, so someone doesn't pull the rug from underneath us
# If specifying a branch here for testing, specify origin/<branch name>
CDH_GIT_HASH=${CDH_GIT_HASH:-2b6d1bced515f10f2f03a856952179f4095a95a1}

# Commitish from github.mtv.cloudera.com/Starship/cmf.git repo
# Taken from a point in time from master branch of cmf.git, so so someone doesn't pull the rug from underneath us
CMF_GIT_HASH=${CMF_GIT_HASH:-2fd32459c94540e725b99ea5d6ea467fea529e79}

# Directory where the massaged output of Spark build goes
# Massaging here refers to addition of wrappers,
# creating empty configs, etc.
BUILD_OUTPUT_DIR=$SPARK_HOME/dist/build_output
# Directory where final repo with parcels and packages will exist
REPO_OUTPUT_DIR=$SPARK_HOME/dist/repo_output
REPO_NAME=spark2-repo
OUTPUT_DIR=$REPO_OUTPUT_DIR/$REPO_NAME/${VERSION/-SNAPSHOT/}
# Directory where cdh.git will get cloned
CDH_CLONE_DIR=${SPARK_HOME}/build/cdh-${CDH_GIT_HASH}

MAKE_MANIFEST_LOCATION=http://github.mtv.cloudera.com/raw/Starship/cmf/${CMF_GIT_HASH}/cli/make_manifest/make_manifest.py

# We are building a non-patch build by default
PATCH_NUMBER=0

BUILDDB_HOST=${BUILDDB_HOST:-"mostrows-builddb.vpc.cloudera.com:8080"}

CSD_WILDCARD="$SPARK_HOME/csd/target/SPARK2_ON_YARN*.jar"
PYTHON_VE=$(mktemp -d /tmp/__spark2_ve.XXXXX)

GBN=

function usage {
  echo "build.sh for building a parcel from source code. Can be called from any working directory."
  echo "Requirements: JAVA_HOME needs to be set, Python 2.7 or higher"
  echo "Call simply as build.sh"
  echo "Options:"
  echo "-h or --help for printing usage"
  echo "-s or --skip-build for skipping the spark2 build. The bits built from last time used to build parcel"
  echo "-p <patch number> or --patch-num <patch number> when building a patch"
  echo "--publish for publishing to S3"
  echo "--build-only for only doing the build (i.e. only building distribution tar.gz, no parcel etc.)"
}

function my_echo {
  echo "BUILD_SCRIPT: $1"
}

function clean {
  rm -rf ${BUILD_OUTPUT_DIR}
  # TODO: You are going to lose your previously build parcels, even if this
  # build fails to generate new parcels. Ugh, sorry, but may be we will fix
  # it later
  rm -rf ${REPO_OUTPUT_DIR}
}

function setup {
# Let's get the Global Build Number before we do anything else
  GBN=$(curl http://gbn.infra.cloudera.com/)
  if [[ -z "$GBN" ]]; then
    >&2 my_echo "Unable to retrieve Global Build Number. Are you sure you are on VPN?"
    exit 1
  fi
  if [[ ! -d $CDH_CLONE_DIR ]]; then
    git clone git://github.mtv.cloudera.com/CDH/cdh.git $CDH_CLONE_DIR
  fi
  (cd $CDH_CLONE_DIR; git fetch; git checkout $CDH_GIT_HASH)
  virtualenv $PYTHON_VE
  source $PYTHON_VE/bin/activate
  REQUIREMENTS=$CDH_CLONE_DIR/lib/python/cauldron/requirements.txt
  SETUP_PY=$CDH_CLONE_DIR/lib/python/cauldron/setup.py
  $PYTHON_VE/bin/pip install -r $REQUIREMENTS
  (cd $(dirname $SETUP_PY) && $PYTHON_VE/bin/python $SETUP_PY install)
}

# Runs the make-distribution command, generates bits under SPARK_HOME/dist
function do_build {
  # We want to cd to SPARK_HOME when calling this function. So, let's start a subshell
  # and cd, so in case it errors we are back in the user's original cwd.
  (
  cd $SPARK_HOME
  # On dev boxes, this variable won't be defined, but on Jenkins boxes, it would be
  # set to deploy to also deploy bits to artifactory
  if [[ -z "${DO_MAVEN_DEPLOY}" ]]; then
      MAVEN_INST_DEPLOY=install
  else
      MAVEN_INST_DEPLOY=$DO_MAVEN_DEPLOY
  fi

  BUILD_OPTS="-Divy.home=${HOME}/.ivy2 -Dsbt.ivy.home=${HOME}/.ivy2 -Duser.home=${HOME} \
              -Drepo.maven.org=$IVY_MIRROR_PROP \
              -Dreactor.repo=file://${HOME}/.m2/repository${M2_REPO_SUFFIX} \
              -DskipTests -DrecompileMode=all"
  # this might be an issue at times
  # http://maven.40175.n5.nabble.com/Not-finding-artifact-in-local-repo-td3727753.html
  export MAVEN_OPTS="-Xmx2g -XX:ReservedCodeCacheSize=512m -XX:PermSize=1024m -XX:MaxPermSize=1024m"

  mkdir -p target/zinc
  # This mktemp works with both GNU (Linux) and BSD (Mac) versions
  MYMVN=$(mktemp target/mvn.XXXXXXXX)
  cat >$MYMVN <<EOF
#!/bin/sh
export ZINC_OPTS="-Dzinc.dir=$SPARK_HOME/target/zinc -Xmx2g -XX:MaxPermSize=512M \
                  -XX:ReservedCodeCacheSize=512m"
export APACHE_MIRROR=http://archive-primary.cloudera.com/tarballs/apache
exec $SPARK_HOME/build/mvn --force "\$@"
EOF
  chmod 700 $MYMVN

  my_echo "Building distribution ..."
  ./dev/make-distribution.sh --tgz --mvn $MYMVN --target $MAVEN_INST_DEPLOY \
   -Dcdh.build=true $BUILD_OPTS

  rm -f $MYMVN
  my_echo "Build completed successfully. Distribution at $SPARK_HOME/dist"
  )
}

# Create binary wrappers, etc.
# Picks up the dist generated by build step under SPARK_HOME/dist and add to it.
function post_build_steps {
  my_echo "Creating binary wrappers ..."
  PREFIX=${BUILD_OUTPUT_DIR}

  LIB_DIR=${LIB_DIR:-/usr/lib/spark2}
  INSTALLED_LIB_DIR=${INSTALLED_LIB_DIR:-/usr/lib/spark2}
  BIN_DIR=${BIN_DIR:-/usr/bin}
  CONF_DIR=${CONF_DIR:-/etc/spark2/conf.dist}

  install -d -m 0755 $PREFIX/$LIB_DIR
  install -d -m 0755 $PREFIX/$LIB_DIR/bin
  install -d -m 0755 $PREFIX/$LIB_DIR/sbin
  install -d -m 0755 $PREFIX/$DOC_DIR

  install -d -m 0755 $PREFIX/var/lib/spark/
  install -d -m 0755 $PREFIX/var/log/spark2/
  install -d -m 0755 $PREFIX/var/run/spark2/
  install -d -m 0755 $PREFIX/var/run/spark2/work/

  # Something like $SPARK_HOME/dist
  PARENT_BUILD_OUTPUT_DIR=$(dirname $BUILD_OUTPUT_DIR)
  # Something like build_output
  BASENAME_BUILD_OUTPUT_DIR=$(basename $BUILD_OUTPUT_DIR)
  # Copy of all contents from build_output to the destination, while making sure
  # not to get in a circular loop
  (cd $PARENT_BUILD_OUTPUT_DIR; cp -r $(ls $PARENT_BUILD_OUTPUT_DIR |\
    grep -v $BASENAME_BUILD_OUTPUT_DIR) $PREFIX/$LIB_DIR)

  install -d -m 0755 $PREFIX/$CONF_DIR
  rm -rf $PREFIX/$LIB_DIR/conf
  ln -s /etc/spark2/conf $PREFIX/$LIB_DIR/conf

  # No default /etc/default/spark2 file is shipped because it's only used by
  # services and in case of parcels, CM manages services, so we are fine here.
  # Not shipping spark-env.sh either

  # Create wrappers
  install -d -m 0755 $PREFIX/$BIN_DIR
  for wrap in bin/spark-shell bin/spark-submit; do
  modified_wrap=$(echo ${wrap} | sed -e 's/spark/spark2/g')
  cat > $PREFIX/$BIN_DIR/$(basename $modified_wrap) <<EOF
#!/bin/bash

# Autodetect JAVA_HOME if not defined
. /usr/lib/bigtop-utils/bigtop-detect-javahome

exec $INSTALLED_LIB_DIR/$wrap "\$@"
EOF
    chmod 755 $PREFIX/$BIN_DIR/$(basename $modified_wrap)
  done

  ln -s /var/run/spark2/work $PREFIX/$LIB_DIR/work

  cat > $PREFIX/$BIN_DIR/pyspark2 <<EOF
#!/bin/bash

# Autodetect JAVA_HOME if not defined
. /usr/lib/bigtop-utils/bigtop-detect-javahome

export PYSPARK_PYTHON=\${PYSPARK_PYTHON:-${PYSPARK_PYTHON}}

exec $INSTALLED_LIB_DIR/bin/pyspark "\$@"
EOF
  chmod 755 $PREFIX/$BIN_DIR/pyspark2

  GIT_HASH=$(cd $SPARK_HOME;git rev-parse HEAD)

  install -d -m 0755 $PREFIX/$LIB_DIR/cloudera
  # Generate cdh_version.properties
  cat > $PREFIX/$LIB_DIR/cloudera/spark2_version.properties <<EOF
# Autogenerated build properties
version=$VERSION
git.hash=$GIT_HASH
cloudera.hash=$GIT_HASH
cloudera.cdh.hash=na
cloudera.cdh-packaging.hash=na
cloudera.base-branch=na
cloudera.build-branch=$(git symbolic-ref --short HEAD)
cloudera.pkg.version=na
cloudera.pkg.release=na
cloudera.cdh.release=$VERSION
cloudera.build.time=$(date -u "+%Y.%m.%d-%H:%M:%SGMT")
cloudera.pkg.name=spark2
EOF
}

function build_parcel {
  # The regex is complicated for grep that's the only one that easily worked
  # with default modes on GNU grep and BSD grep (given that we have some mac
  # users on the team)
  CDH_VERSION=$(cd $SPARK_HOME;build/mvn -Dcdh.build=true help:evaluate \
                -Dexpression=hadoop.version |\
                grep "^[0-9]\+\.[0-9]\+\.[0-9]\+-cdh[0-9]\+\.[0-9]\+\.[0-9]\+$" |\
                sed -e 's/.*-cdh\(.*\)/\1/g')
  if [[ -z "$CDH_VERSION" ]]; then
    >&2 my_echo "Unable to find the version of CDH, Spark2 was built against."
    exit 1
  fi

  # util.py needs to exist in $SPARK_HOME/cloudera directory because it's used by
  # a python module (build_parcel.py) from that directory as well. Let's force
  # overwrite to make sure we never the stale version
  (cd $SPARK_HOME/cloudera; rm -f util.py; cp ${CDH_CLONE_DIR}/bin/parcel/util.py .)

  ${SPARK_HOME}/cloudera/build_parcel.py --input-directory ${BUILD_OUTPUT_DIR} \
  --output-directory ${OUTPUT_DIR}/parcels --release-version 1 \
  --spark2-version $VERSION --cdh-version $CDH_VERSION --build-number $GBN \
  --patch-number ${PATCH_NUMBER} --verbose --force-clean

  mkdir -p ${OUTPUT_DIR}/csd
  cp ${CSD_WILDCARD} ${OUTPUT_DIR}/csd
}

function populate_manifest {
  # curl -O overwrites, if the file already exists, so we don't have to worry about that
  (cd $SPARK_HOME/target; curl -O $MAKE_MANIFEST_LOCATION)
  chmod 755 $SPARK_HOME/target/make_manifest.py
  $SPARK_HOME/target/make_manifest.py ${OUTPUT_DIR}/parcels
}

function populate_build_json {
  OS_ARGS=""
  for os in $(awk '{print $2}' $SPARK_HOME/cloudera/supported_oses.txt); do
    OS_ARGS=$OS_ARGS" --os $os"
  done

  CSD_ARGS=""
  for csd in ${CSD_WILDCARD}; do
    CSD_ARGS=$CSD_ARGS" --csd $(basename $csd)"
  done

  $PYTHON_VE/bin/python ${CDH_CLONE_DIR}/lib/python/cauldron/src/cauldron/tools/buildjson.py \
    -o ${REPO_OUTPUT_DIR}/build.json \
    --product-base spark2:${REPO_NAME} \
    --version ${VERSION/-SNAPSHOT/} \
    --parcel-patch-number $PATCH_NUMBER \
    --user $USER \
    --repo ${SPARK_HOME} \
    --gbn $GBN \
    $OS_ARGS \
    -s ${CDH_CLONE_DIR}/build-schema.json \
    --parcels \
    $CSD_ARGS
}

function publish {
  # This file with GBN in it seems to be required by upload.py
  echo ${GBN} > ${REPO_OUTPUT_DIR}/gbn.txt
  $PYTHON_VE/bin/python ${CDH_CLONE_DIR}/lib/python/cauldron/src/cauldron/tools/upload.py  ${REPO_OUTPUT_DIR}:${GBN}
  curl http://${BUILDDB_HOST}/save?gbn=${GBN}
}

# This is where the main part begins
while [[ $# -ge 1 ]]; do
  arg=$1
  case $arg in
    -p|--patch-num)
    PATCH_NUMBER="$2"
    shift
    ;;
    -s|--skip-build)
    SKIP_BUILD=true
    ;;
    --publish)
    PUBLISH=true
    ;;
    --build-only)
    BUILD_ONLY=true
    ;;
    -h|--help)
    usage
    exit 0
    ;;
    *)
    ;;
  esac
  shift
done

clean
setup

if [[ "$SKIP_BUILD" = true ]] && [[ "$BUILD_ONLY" = true ]]; then
  my_echo "Can not set --skip-build and --build-only at the same time"
  exit 1
fi

if [[ "$PUBLISH" = true ]] && [[ "$BUILD_ONLY" = true ]]; then
  my_echo "Can not set --publish and --build-only at the same time"
  exit 1
fi

if [[ "$SKIP_BUILD" = false ]]; then
  do_build
fi

if [[ "$BUILD_ONLY" != true ]]; then
  post_build_steps
  build_parcel
  populate_manifest
  populate_build_json
  if [[ "$PUBLISH" = true ]]; then
    publish
  fi
fi

my_echo "Build completed. Success!"
