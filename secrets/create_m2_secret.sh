#!/usr/bin/env bash
#*******************************************************************************
# Copyright (c) 2019 Eclipse Foundation and others.
# This program and the accompanying materials are made available
# under the terms of the Eclipse Public License 2.0
# which is available at http://www.eclipse.org/legal/epl-v20.html,
# or the MIT License which is available at https://opensource.org/licenses/MIT.
# SPDX-License-Identifier: EPL-2.0 OR MIT
#*******************************************************************************

# This script generates a secret in OpenShift that contains the Maven settings file and the settings-security file.

# Bash strict-mode
set -o errexit
set -o nounset
set -o pipefail

IFS=$'\n\t'
script_name="$(basename ${0})"

project_name="${1:-}"

pw_store_root_dir=~/.password-store
pw_store_path=cbi-pass/bots/${project_name}
mvn_master_pw_path=${pw_store_path}/apache-maven-security-settings/master-password

usage() {
  printf "Usage: %s project_name\n" "$script_name"
  printf "\t%-16s project name (e.g. technology.cbi for CBI project).\n" "project_name"
}

# check that project name is not empty
if [[ -z "${project_name}" ]]; then
  printf "ERROR: a project name must be given.\n"
  usage
  exit 1
fi

# check that project name contains a dot
if [[ "$project_name" != *.* ]]; then
  printf "ERROR: the full project name with a dot must be given (e.g. technology.cbi).\n"
  usage
  exit 1
fi

short_name=${project_name##*.}
temp_path=/tmp/${short_name}
mvn_settings_file=${temp_path}/settings.xml
mvn_security_file=${temp_path}/settings-security.xml

mkdir -p ${temp_path}

pw_gen() {
  # If pwgen is not installed, use /dev/urandom instead
  if hash pwgen 2>/dev/null; then
    pwgen -1 -s -y $1
  else
    </dev/urandom tr -dc 'A-Za-z0-9!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~' | head -c $1
  fi
}

generate_master_pw() {
  local master_pw=$(pw_gen 24)
  pass insert --echo ${mvn_master_pw_path} <<< "${master_pw}"
}

yes_no_exit() {
  local do_what=$1
  local exec_if_yes=$2
  local exec_if_no=$3
  read -p "Do you want to ${do_what}? (Y)es, (N)o, E(x)it: " yn
  case $yn in
    [Yy]* ) ${exec_if_yes};;
    [Ss]* ) ${exec_if_no};;
    [Xx]* ) exit;;
        * ) echo "Please answer (Y)es, (N)o, E(x)it";;
  esac
}

create_mvn_security_file() {
  # check if master pw exists in pass
  if [ ! -f ${pw_store_root_dir}/${mvn_master_pw_path}.gpg ]; then
    printf "ERROR: Maven master password is missing in pass.\n"
    yes_no_exit "generate a new Maven master password" generate_master_pw exit
  fi

  # encrypt master pw
  master_pw=$(pass ${mvn_master_pw_path})
  master_pw_enc=$(mvn --encrypt-master-password "$(printf "%s" ${master_pw})" -Dsettings.security=${mvn_security_file})
  #master_pw_enc=$(mvn --encrypt-master-password <<< "${master_pw}")

  # generate security-settings.xml file
  cat <<EOG > ${mvn_security_file}
<settingsSecurity>
  <master>${master_pw_enc}</master>
</settingsSecurity>
EOG

  printf "settings-security.xml:\n"
  cat ${mvn_security_file}
}

generate_ossrh_settings() {
  ossrh_pw_path=${pw_store_path}/oss.sonatype.org/password
  # check if pw exists in pass
  if [ ! -f ${pw_store_root_dir}/${ossrh_pw_path}.gpg ]; then
    printf "ERROR: OSSRH password is missing in pass.\n"
    exit 1
  fi

  # encrypt ossrh pw
  ossrh_user=$(pass ${pw_store_path}/oss.sonatype.org/username)
  ossrh_pw=$(pass ${ossrh_pw_path})
  ossrh_pw_enc=$(mvn --encrypt-password $(printf "%s" ${ossrh_pw}) -Dsettings.security=${mvn_security_file})
  #ossrh_pw_enc=$(mvn --encrypt-password <<< "${ossrh_pw}")

cat <<EOF2 >> ${mvn_settings_file}
    <server>
      <id>ossrh</id>
      <username>${ossrh_user}</username>
      <password>${ossrh_pw_enc}</password>
    </server>
EOF2
}

generate_gpg_settings() {
  gpg_pw_path=${pw_store_path}/gpg/passphrase
  # check if pw exists in pass
  if [ ! -f ${pw_store_root_dir}/${gpg_pw_path}.gpg ]; then
    printf "ERROR: GPG passphrase is missing in pass.\n"
    exit 1
  fi
  # encrypt gpg passphrase
  gpg_pw=$(pass ${gpg_pw_path})
  gpg_pw_enc=$(mvn --encrypt-password "$(printf "%s" ${gpg_pw})" -Dsettings.security=${mvn_security_file})
  #gpg_pw_enc=$(mvn --encrypt-password <<< "${gpg_pw}")

cat <<EOF3 >> ${mvn_settings_file}
    <server>
      <id>gpg.passphrase</id>
      <passphrase>${gpg_pw_enc}</passphrase>
    </server>
EOF3
}

generate_mvn_settings() {
  read -sp "Nexus password: " nexus_pw
  echo
  nexus_pw_enc=$(mvn --encrypt-password $(printf "%s" ${nexus_pw}) -Dsettings.security=${mvn_security_file})

  cat <<EOF1 > ${mvn_settings_file}
<settings>
  <servers>
    <server>
      <id>repo.eclipse.org</id>
      <username>deployment</username>
      <password>${nexus_pw_enc}</password>
    </server>
EOF1

yes_no_exit "add OSSRH credentials" generate_ossrh_settings :

yes_no_exit "add GPG credentials" generate_gpg_settings :

  cat <<EOF4 >> ${mvn_settings_file}
  </servers>
  <mirrors>
    <mirror>
      <id>eclipse.maven.central.mirror</id>
      <name>Eclipse Central Proxy</name>
      <url>https://repo.eclipse.org/content/repositories/maven_central/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF4

  printf "\n${mvn_settings_file}:\n"
  cat ${mvn_settings_file}
}

add_secret_to_k8s() {
  if [ -f ${mvn_settings_file} ] && [ -f ${mvn_security_file} ]; then
    oc create secret generic m2-secret-dir --namespace=${short_name} --from-file=${mvn_settings_file} --from-file=${mvn_security_file}
  else
    echo "ERROR: ${mvn_settings_file} and/or ${mvn_security_file} do not exist."
  fi
}

create_mvn_security_file
generate_mvn_settings
add_secret_to_k8s

rm -rf ${temp_path}

echo "Done."