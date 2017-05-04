#!/bin/bash
#
# Publish the FIBO ontologies
#
# This script needs to be run in a Jenkins workspace, where two git repos are cloned:
#
# - fibo (in ${WORKSPACE}/fibo directory)
# - fibo-infra (in ${WORKSPACE}/fibo-infra directory)
#
#
SCRIPT_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd -P)"

tmp_dir="${WORKSPACE}/tmp"
fibo_root=""
fibo_infra_root=""
jena_arq=""

#
# The products that we generate the artifacts for with this script
#
# ontology has to come before glossary because glossary depends on it.
#
products="ontology glossary"

spec_root="${WORKSPACE}/target"
family_root="${spec_root}/fibo"
branch_root=""
tag_root=""

spec_root_url="https://spec.edmcouncil.org"
family_root_url="${spec_root_url}/fibo"
product_root=""
product_root_url=""
branch_root_url=""
tag_root_url=""

modules=""
module_directories=""

stardog_vcs=""

rdftoolkit_jar="${WORKSPACE}/rdf-toolkit.jar"

shopt -s globstar

trap "rm -rf ${tmp_dir} >/dev/null 2>&1" EXIT

#
# This is for tools like pandoc
#
. /home/ec2-user/.nix-profile/etc/profile.d/nix.sh

function require() {

  local variableName="$1"

  export | grep -q "declare -x ${variableName}=" && return 0
  declare | grep -q "^${variableName}="&& return 0

  set -- $(caller 0)

  echo "ERROR: The function $2() (line $1) (in $3) requires ${variableName}" >&2

  exit 1
}

function error() {

  local line="$@"

  set -- $(caller 0)

  echo "ERROR: in function $2() (line $1) (in $3): ${line}" >&2
}

function logRule() {

  echo $(printf '=%.0s' {1..40}) $@ >&2
}

function initWorkspaceVars() {

  #tmp_dir=$(mktemp -d "${tmp_dir:-/tmp}/$(basename 0).XXXXXXXXXXXX")
  mkdir -p "${tmp_dir}" >/dev/null 2>&1
  echo tmp_dir=${tmp_dir}

  fibo_root="${WORKSPACE}/fibo"
  echo "fibo_root=${fibo_root}"

  if [ ! -d "${fibo_root}" ] ; then
    echo "ERROR: fibo_root directory not found (${fibo_root})"
    return 1
  fi

  export fibo_infra_root="$(cd ${SCRIPT_DIR}/../.. ; pwd -L)"
  echo fibo_infra_root=${fibo_infra_root}

  if [ ! -d "${fibo_infra_root}" ] ; then
    echo "ERROR: fibo_infra_root directory not found (${fibo_infra_root})"
    return 1
  fi


  if [ ! -f "${rdftoolkit_jar}" ] ; then
    echo "ERROR: Put the rdf-toolkit.jar in the workspace as a pre-build step"
    return 1
  fi

  #
  # We should install Jena on the Jenkins server and not have it in the git-repo, takes up too much space for each
  # release of Jena
  #
  export JENAROOT="${fibo_infra_root}/bin/apache-jena-3.0.1"
  jena_bin="${JENAROOT}/bin"
  jena_arq="${jena_bin}/arq"
  jena_riot="${jena_bin}/riot"
  chmod a+x ${jena_bin}/*

  export JENA2ROOT="${fibo_infra_root}/bin/apache-jena-2.11.0"

  if [ ! -f "${jena_arq}" ] ; then
    echo "ERROR: ${jena_arq} not found"
    return 1
  fi

  return 0
}

#
# Since this script deals with multiple products (ontology, glossary etc) we need to be able to switch back
# and forth, call this function whenever you generate something for another product. The git branch and tag name
# always remains the same though.
#
function setProduct() {

  local product="$1"

  require GIT_BRANCH || return $?
  require GIT_TAG_NAME || return $?

  product_root="${family_root}/${product}"
  product_root_url="${family_root_url}/${product}"

  if [ ! -d "${product_root}" ] ; then
    mkdir -p "${product_root}"
  fi

  branch_root="${product_root}/${GIT_BRANCH}"
  branch_root_url="${product_root_url}/${GIT_BRANCH}"

  if [ ! -d "${branch_root}" ] ; then
    mkdir -p "${branch_root}"
  fi

  tag_root="${branch_root}/${GIT_TAG_NAME}"
  tag_root_url="${branch_root_url}/${GIT_TAG_NAME}"

  if [ ! -d "${tag_root}" ] ; then
    mkdir -p "${tag_root}"
  fi

  return 0
}

function initGitVars() {

  export GIT_COMMENT=$(cd ${fibo_root} ; git log --format=%B -n 1 ${GIT_COMMIT})
  echo "GIT_COMMENT=${GIT_COMMENT}"

  export GIT_AUTHOR=$(cd ${fibo_root} ; git show -s --pretty=%an)
  echo "GIT_AUTHOR=${GIT_AUTHOR}"

  #
  # Get the git branch name to be used as directory names and URL fragments and make it
  # all lower case
  #
  export GIT_BRANCH=$(cd ${fibo_root} ; git rev-parse --abbrev-ref HEAD | tr '[:upper:]' '[:lower:]')
  #
  # Replace all slashes in a branch name with dashes so that we don't mess up the URLs for the ontologies
  #
  GIT_BRANCH="${GIT_BRANCH//\//-}"
  echo "GIT_BRANCH=${GIT_BRANCH}"

  #
  # If the current commit has a tag associated to it then the Git Tag Message Plugin in Jenkins will
  # initialize the GIT_TAG_NAME variable with that tag. Otherwise set it to "latest"
  #
  # See https://wiki.jenkins-ci.org/display/JENKINS/Git+Tag+Message+Plugin
  #
  export GIT_TAG_NAME="${GIT_TAG_NAME:-latest}"
  echo "GIT_TAG_NAME=${GIT_TAG_NAME}"

  #
  # Set default product
  #
  setProduct ontology

  return 0
}

function initJiraVars() {

  export JIRA_ISSUE="$(echo $GIT_COMMENT | rev | grep -oP '\d+-[A-Z0-9]+(?!-?[a-zA-Z]{1,10})' | rev)"
  echo JIRA_ISSUE="${JIRA_ISSUE}"
}

function initStardogVars() {

  export STARDOG_HOME=/usr/local/stardog-home
  export STARDOG_BIN=/usr/local/stardog/bin

  stardog_vcs="${STARDOG_BIN}/stardog vcs"
}

#
# Create an about file in RDF/XML format, do this BEFORE we convert all .rdf files to the other
# formats so that this about file will also be converted.
#
# TODO: Generate this at each directory level in the tree
#
# TODO: Should be done for each serialization format
#
function ontologyCreateAboutFiles () {

  local tmpAboutFile="$(mktemp ${tmp_dir}/ABOUT.XXXXXX.ttl)"
  local echoq="$(mktemp ${tmp_dir}/echo.sparqlXXXXXX)"

  (
    cd ${tag_root}

    cat > "${tmpAboutFile}" << __HERE__
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> 
@prefix owl: <http://www.w3.org/2002/07/owl#> 
@prefix xsd: <http://www.w3.org/2001/XMLSchema#>
<${tag_root_url}/AboutFIBO> a owl:Ontology;
__HERE__

    grep \
      -r "xml:base" \
      $( \
        find . -mindepth 1  -maxdepth 1 -type d -print | \
        grep -vE "(etc)|(git)"
      ) | \
      grep -v catalog | \
      sed 's/^.*xml:base="/owl:imports </;s/" *$/> ;/' \
      >> "${tmpAboutFile}"

    cat > "${echoq}" << __HERE__
CONSTRUCT {?s ?p ?o} WHERE {?s ?p ?o}
__HERE__

    "${jena_arq}" --data="${tmpAboutFile}" --query="${echoq}" --results=RDF > AboutFIBO.rdf
  )
}

#
# Copy all publishable files from the fibo repo to the appropriate target directory (${tag_root})
# where they will be converted to publishable artifacts
#
function ontologyCopyRdfToTarget() {

  local module
  local upperModule

  echo "Copying all artifacts that we publish straight from git into target directory"

  pushd ${fibo_root}
  #
  # Don' copy all files with all extensions at the same time since it gives nasty errors when files without the
  # given extension are not found.
  #
  for extension in rdf ttl md jpg png gif docx pdf sq ; do
    echo "Copying fibo/**/*.${extension} to ${tag_root/${WORKSPACE}}"
    cp **/*.${extension} --parents ${tag_root}/
  done

  #cp **/*.{rdf,ttl,md,jpg,png,docx,pdf,sq} --parents ${tag_root}/
  popd

  #
  # Rename the lower case module directories as we have them in the fibo git repo to
  # upper case directory names as we serve them on spec.edmcouncil.org
  #
  pushd ${tag_root}
  for module in * ; do
    [ -d ${module} ] || continue
    [ "${module}" == "etc" ] && continue
    [ "${module}" == "ext" ] && continue
    upperModule=$(echo ${module} | tr '[:lower:]' '[:upper:]')
    [ "${module}" == "${upperModule}" ] && continue
    mv ${module} ${upperModule}
  done
  modules=""
  module_directories=""
  for module in * ; do
    [ -d ${module} ] || continue
    [ "${module}" == "etc" ] && continue
    [ "${module}" == "ext" ] && continue
    modules="${modules} ${module}"
    module_directories="${modules_directories} $(pwd)/${module}"
  done
  popd

  #
  # Clean up a few things that are too embarrassing to publish
  #
  rm -vrf ${tag_root}/etc >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/cm >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/source >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/infra >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/image >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/spec >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/testing >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/odm >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/uml >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/process >/dev/null 2>&1
#  rm -vrf ${tag_root}/etc/operational >/dev/null 2>&1
  rm -vrf ${tag_root}/**/archive >/dev/null 2>&1
  rm -vrf ${tag_root}/**/Bak >/dev/null 2>&1

  #find ${tag_root}

  return 0
}

function ontologySearchAndReplaceStuff() {

  echo "Replacing stuff in RDF files"

  local sedfile=$(mktemp ${tmp_dir}/sed.XXXXXX)
  
  cat > "${sedfile}" << __HERE__
#
# First replace all http:// urls to https:// if that's not already done
#
s@http://spec.edmcouncil.org@${spec_root_url}@g
#
#
#
s@${family_root_url}/\([A-Z]*\)/@${product_root_url}/\1/@g
#
# Replace
# - https://spec.edmcouncil.org/fibo/ontology/BE/20150201/
# with
# - https://spec.edmcouncil.org/fibo/ontology/BE/
#
s@${product_root_url}/\([A-Z]*\)/[0-9]*/@${product_root_url}/\1/@g
#
# Replace all fibo IRIs with a versioned one so
#
# - https://spec.edmcouncil.org/fibo/ontology/ becomes
# - https://spec.edmcouncil.org/fibo/ontology/<branch>/<tag>/
#
s@\(${product_root_url}/\)@\1${GIT_BRANCH}/${GIT_TAG_NAME}/@g
#
# Now remove the branch and tag name from all the xml:base statements
#
s@\(xml:base="${product_root_url}/\)${GIT_BRANCH}/${GIT_TAG_NAME}/@\1@g
#
# And from all the rdf:about statements
#
s@\(rdf:about="${product_root_url}/\)${GIT_BRANCH}/${GIT_TAG_NAME}/@\1@g
#
# And all ENTITY statements
#
s@\(<!ENTITY.*${product_root_url}/\)${GIT_BRANCH}/${GIT_TAG_NAME}/@\1@g
#
# And all xmlns:fibo* lines
#
s@\(xmlns:fibo.*${product_root_url}/\)${GIT_BRANCH}/${GIT_TAG_NAME}/@\1@g

__HERE__

  cat "${sedfile}"

  (
    set -x
    find ${tag_root}/ -type f \( -name '*.rdf' -o -name '*.ttl' -o -name '*.md' \) -exec sed -i -f ${sedfile} {} \;
  )

  return 0
}

function TBCAnnotate() {
        # For the .ttl files, find the ontology, and compute the version IRI from it.  Put it in a cookie where TopBraid will find it. 
    local GIT_BRANCH=master
    local GIT_TAG_NAME=latest
    local product_root_url="https://spec.edmcouncil.org/fibo/ontology/"
    echo "$1"
    local qf="$(mktemp ${tmp_dir}/ontXXXXXX.sq)"
#  local qf=ont.sq
    cat > "$qf" << EOF
SELECT ?o WHERE {?o a <http://www.w3.org/2002/07/owl#Ontology> .}
EOF
    arq --query="$qf" --data="$1" --results=csv | grep edmcouncil
    uri="#baseURI: $(arq --query="$qf" --data="$1" --results=csv | grep edmcouncil | sed "s@\(https://spec.edmcouncil.org/fibo/ontology/\)@\1${GIT_BRANCH}/${GIT_TAG_NAME}/@")"
    echo "($uri)"
    sed -i "1s;^;$uri\n;" "$1"
}





function ontologyConvertMarkdownToHtml() {

  echo "Convert Markdown to HTML"

  pushd "${tag_root}"
  for markdownFile in **/*.md ; do
    echo "Convert ${markdownFile} to html"
    pandoc --standalone --from markdown --to html -o "${markdownFile/.md/.html}" "${markdownFile}"
  done
  popd

  return 0
}

#
# TODO: Omar can you look at this? Do we still need this?
#
function storeVersionInStardog() {

  echo "Commit to Stardog..."
  ${stardog_vcs} commit --add $(find ${tag_root} -name "*.rdf") -m "$GIT_COMMENT" -u obkhan -p stardogadmin ${GIT_BRANCH}
  SVERSION=$(${stardog_vcs} list --committer obkhan --limit 1 ${GIT_BRANCH} | sed -n -e 's/^.*Version:   //p')
  ${stardog_vcs} tag --drop $JIRA_ISSUE ${GIT_BRANCH} || true
  ${stardog_vcs} tag --create $JIRA_ISSUE --version $SVERSION ${GIT_BRANCH}
}

function convertRdfFileTo() {

  local sourceFormat="$1"
  local rdfFile="$2"
  local targetFormat="$3"
  local rdfFileNoExtension="${rdfFile/.rdf/}"
  local rdfFileNoExtension="${rdfFileNoExtension/.ttl/}"
  local rdfFileNoExtension="${rdfFileNoExtension/.jsonld/}"
  local targetFile="${rdfFileNoExtension}"
  local rc=0
  local logfile=$(mktemp ${tmp_dir}/convertRdfFileTo.XXXXXX)

  case ${targetFormat} in
    rdf-xml)
      targetFile="${targetFile}.rdf"
      ;;
    json-ld)
      targetFile="${targetFile}.jsonld"
      ;;
    turtle)
      targetFile="${targetFile}.ttl"
      ;;
    *)
      echo "ERROR: Unsupported format ${targetFormat}"
      return 1
      ;;
  esac

  java \
    -jar "${rdftoolkit_jar}" \
    --source "${rdfFile}" \
    --source-format "${sourceFormat}" \
    --target "${targetFile}" \
    --target-format "${targetFormat}" \
    > "${logfile}" 2>&1
  rc=$?

  if grep -q "ERROR" "${logfile}"; then
    echo "Found errors during conversion of ${rdfFile} to \"${targetFormat}\":"
    cat "${logfile}"
    rm "${logfile}"
    return 1
  fi
  rm "${logfile}"
  echo "Conversion of ${rdfFile} to \"${targetFormat}\" was successful"

  return ${rc}
}

#
# Now use the rdf-toolkit serializer to create copies of all .rdf files in all the supported RDF formats
#
# Using the Sesame serializer, here' the documentation:
#
# https://github.com/edmcouncil/rdf-toolkit/blob/master/docs/SesameRdfFormatter.md
#
function ontologyConvertRdfToAllFormats() {

  pushd "${tag_root}"

  for rdfFile in **/*.rdf ; do
    for format in json-ld turtle ; do
      convertRdfFileTo rdf-xml "${rdfFile}" "${format}" || return $?
    done || return $?
  done || return $?

  popd

  return $?
}

function glossaryConvertTurtleToAllFormats() {

  pushd "${tag_root}"

  for ttlFile in **/*.ttl ; do
    for format in json-ld rdf-xml ; do
      convertRdfFileTo turtle "${ttlFile}" "${format}" || return $?
    done || return $?
  done || return $?

  popd

  return $?
}

#
# We need to put the output of this job in a directory next to all other branches and never delete any of the
# other formerly published branches.
#
function zipWholeTagDir() {

  local tarGzFile="${branch_root}/${GIT_TAG_NAME}.tar.gz"

  (
    cd ${spec_root}
    set -x
    tar -cvzf "${tarGzFile}" "${tag_root/${spec_root}/.}"
  )

  echo "Created ${tarGzFile}:"
  ls -al "${tarGzFile}" || return $?

  return 0
}

#
# Copy the static files of the site
#
function copySiteFiles() {

  (
    cd ${fibo_infra_root}/site
    cp -vr * "${spec_root}/"
  )
  cp -v ${fibo_infra_root}/LICENSE ${spec_root}

  return 0
}

function publishProductOntology() {

  logRule "Publishing the ontology product"

  setProduct ontology || return $?

  ontologyCopyRdfToTarget || return $?
  ontologyCreateAboutFiles || return $?
  ontologySearchAndReplaceStuff || return $?
  ontologyConvertRdfToAllFormats || return $?
  ontologyConvertMarkdownToHtml || return $?

  return 0
}

#
# Called by publishProductGlossary(), sets the names of all modules in the global variable modules and their
# root directories in the global variable module_directories
#
# 1) Determine which modules will be included. They are kept on a property
#    called <http://www.edmcouncil.org/skosify#module> in skosify.ttl
#
# JG>Apache jena3 is also installed on the Jenkins server itself, so maybe
#    no need to have this in the fibs-infra repo.
#
function glossaryGetModules() {

  require glossary_script_dir || return $?
  require ontology_product_tag_root || return $?

  echo "Query the skosify.ttl file for the list of modules (TODO: Should come from rdf-toolkit.ttl)"

  ${jena_arq} \
    --results=CSV \
    --data="${glossary_script_dir}/skosify.ttl" \
    --query="${glossary_script_dir}/get-module.sparql" | grep -v list > \
    "${tmp_dir}/module"

  if [ ${PIPESTATUS[0]} -ne 0 ] ; then
    error "Could not get modules"
    return 1
  fi

  cat ${tmp_dir}/module
  export modules="$(< ${tmp_dir}/module)"

  export module_directories="$(for module in ${modules} ; do echo -n "${ontology_product_tag_root}/${module} " ; done)"

  echo "Found the following modules:"
  echo ${modules}

  echo "Using the following directories:"
  echo ${module_directories}

  rm -f "${tmp_dir}/module"

  return 0
}

#
# 2) Compute the prefixes we'll need.
#
function glossaryGetPrefixes() {

  require glossary_script_dir || return $?
  require ontology_product_tag_root || return $?
  require modules || return $?
  require module_directories || return $?

  echo "Get prefixes"

  pushd ${ontology_product_tag_root}
  grep -R --include "*.ttl" --no-filename "@prefix fibo-" | sort -u > "${tmp_dir}/prefixes.ttl"
  popd

  echo "Found the following prefixes:"
  cat "${tmp_dir}/prefixes.ttl"

  return 0
}

#
# 3) Gather up all the RDF files in those modules.  Include skosify.ttl, since that has the rules
#
# Generates tmp_dir/temp0.ttl
#
function glossaryGetOntologies() {

  require glossary_script_dir || return $?
  require module_directories || return $?

  echo "Get Ontologies into merged file (temp0.ttl)"

  ${jena_arq} \
    $(find  ${module_directories} -name "*.rdf" | sed "s/^/--data=/") \
    --data="${glossary_script_dir}/skosify.ttl" \
    --data="${glossary_script_dir}/datatypes.rdf" \
    --query="${glossary_script_dir}/skosecho.sparql" \
    --results=TTL > "${tmp_dir}/temp0.ttl"

  if [ ${PIPESTATUS[0]} -ne 0 ] ; then
    error "Could not get ontologies"
    return 1
  fi

  set +x

  echo "Generated ${tmp_dir}/temp0.ttl:"

  head -n200 "${tmp_dir}/temp0.ttl"

  return 0
}

function spinRunInferences() {

  local inputFile="$1"
  local outputFile="$2"

  require JENA2ROOT || return $?

  (
    set -x
    java \
      -Xmx2g \
      -Dlog4j.configuration="file:${JENA2ROOT}/jena-log4j.properties" \
      -cp "${JENA2ROOT}/lib/*:${fibo_infra_root}/lib:${fibo_infra_root}/lib/SPIN/spin-1.3.3.jar" \
      org.topbraid.spin.tools.RunInferences \
      http://example.org/example \
      "${inputFile}" >> "${outputFile}"
    if [ ${PIPESTATUS[0]} -ne 0 ] ; then
      error "Could not run spin on ${inputFile}"
      return 1
    fi
  )
  [ $? -ne 0 ] && return 1

  return 0
}

#
# Run SPIN
#
# JG>WHat does this do?
#
# Generates tmp_dir/temp1.ttl
#
function glossaryRunSpin() {

  echo "STARTING SPIN"

  rm -f "${tmp_dir}/temp1.ttl" >/dev/null 2>&1

  spinRunInferences "${tmp_dir}/temp0.ttl" "${tmp_dir}/temp1.ttl" || return $?

  echo "Generated ${tmp_dir}/temp1.ttl:"

  head -n50 "${tmp_dir}/temp1.ttl"

  return 0
}

#
# 4) Run the schemify rules.  This adds a ConceptScheme to the output.
#
function glossaryRunSchemifyRules() {

  echo "Run the schemify rules"

  ${jena_arq} \
    --data="${tmp_dir}/temp1.ttl" \
    --data="${glossary_script_dir}/schemify.ttl" \
    --query="${glossary_script_dir}/skosecho.sparql" \
    --results=TTL > "${tmp_dir}/temp2.ttl"

  if [ ${PIPESTATUS[0]} -ne 0 ] ; then
    error "Could not run the schemify rules"
    return 1
  fi

  return 0
}

#
# Turns FIBO in to FIBO-V
#
# The translation proceeds with the following steps:
#
# 1) Start the output with the standard prefixes.  They are in a file called skosprefixes.
# 2) Determine which modules will be included. They are kept on a property called <http://www.edmcouncil.org/skosify#module> in skosify.ttl
# 3) Gather up all the RDF files in those modules
# 4) Run the shemify rules.  This adds a ConceptScheme to the output.
# 5) Merge the ConceptScheme triples with the SKOS triples
# 6) Convert upper cases.  We have different naming standards in FIBO-V than in FIBO.
# 7) Remove all temp files.
#
# The output is in .ttl form in a file called fibo-v.ttl
#
function publishProductGlossary() {

  require JENAROOT || return $?

  logRule "Publishing the glossary product"

  setProduct ontology
  ontology_product_tag_root="${tag_root}"

  setProduct glossary || return $?

  cd "${SCRIPT_DIR}/fibo-glossary" || return $?
  glossary_script_dir=$(pwd)
  chmod a+x ./*.sh

  #
  # 1) Start the output with the standard prefixes.  They are in a file called skosprefixes.
  #
  echo "# baseURI: ${product_root_url}" > ${tmp_dir}/fibo-v1.ttl
  #cat skosprefixes >> ${tmp_dir}/fibo-v1.ttl

  #glossaryGetModules || return $?
  glossaryGetPrefixes || return $?
  glossaryGetOntologies || return $?
  glossaryRunSpin || return $?
  glossaryRunSchemifyRules || return $?

  echo "second run of spin"
  spinRunInferences "${tmp_dir}/temp2.ttl" "${tmp_dir}/tc.ttl" || return $?

  echo "ENDING SPIN"
  #
  # 5) Merge the ConceptScheme triples with the SKOS triples
  #
  ${jena_arq}  \
    --data="${tmp_dir}/tc.ttl" \
    --data="${tmp_dir}/temp1.ttl" \
    --query="${glossary_script_dir}/echo.sparql" \
    --results=TTL > "${tmp_dir}/fibo-uc.ttl"
  #
  # 6) Convert upper cases.  We have different naming standards in FIBO-V than in FIBO.
  #
  sed "s/uc(\([^)]*\))/\U\1/g" "${tmp_dir}/fibo-uc.ttl" >> ${tmp_dir}/fibo-v1.ttl
  ${jena_arq}  \
    --data="${tmp_dir}/fibo-v1.ttl" \
    --query="${glossary_script_dir}/echo.sparql" \
    --results=TTL > "${tmp_dir}/fibo-v.ttl"

  #
  # Adjust namespaces
  #
  ${jena_riot} "${tmp_dir}/fibo-v.ttl" > "${tmp_dir}/fibo-v.nt"
  cat \
    "${glossary_script_dir}/basic-prefixes.ttl" \
    "${tmp_dir}/prefixes.ttl" \
    "${tmp_dir}/fibo-v.nt" | \
  ${jena_riot} \
    --syntax=turtle \
    --output=turtle > \
    "${tag_root}/fibo-v.ttl"

  #
  # JG>Dean I didn't find any hygiene*.sparql files anywhere
  #
#  echo "Running tests"
#  find ${glossary_script_dir}/testing -name 'hygiene*.sparql' -print
#  find ${glossary_script_dir}/testing -name 'hygiene*.sparql' \
#    -exec ${jena_arq} --data="${tag_root}/fibo-v.ttl" --query={} \;

  glossaryConvertTurtleToAllFormats || return $?

  gzip --best --stdout "${tag_root}/fibo-v.ttl" > "${tag_root}/fibo-v.ttl.gz"
  gzip --best --stdout "${tag_root}/fibo-v.rdf" > "${tag_root}/fibo-v.rdf.gz"
  gzip --best --stdout "${tag_root}/fibo-v.jsonld" > "${tag_root}/fibo-v.jsonld.gz"

  echo "Finished publishing the Glossary Product"

  return 0
}

function main() {

  (
    set -x
    rm -rf "${spec_root}"
    mkdir -p "${spec_root}"
  )

  initWorkspaceVars || return $?
  initGitVars || return $?
  initJiraVars || return $?

  for product in ${products} ; do
    case ${product} in
      ontology)
        publishProductOntology || return $?
        ;;
      glossary)
        publishProductGlossary || return $?
        ;;
      *)
        echo "ERROR: Unknown product ${product}"
        ;;
     esac
  done

  zipWholeTagDir || return $?

  copySiteFiles || return $?
}

main $@
exit $?
