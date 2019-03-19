#!/bin/bash

set -o nounset
set -o errexit

scriptdir=$(dirname "$0")
cd "$scriptdir"
setup_only=0
own_vm=0
DEVENVTAG=latest
IMAGE=opencontrailnightly/developer-sandbox

# variables that can be redefined outside
REGISTRY_PORT=${REGISTRY_PORT:-6666}
REGISTRY_IP=${REGISTRY_IP:-}

while getopts ":t:i:sb" opt; do
  case $opt in
    i)
      IMAGE=$OPTARG
      ;;
    t)
      DEVENVTAG=$OPTARG
      ;;
    s)
      setup_only=1
      ;;
    b)
      own_vm=1
      ;;
    \?)
      echo "Invalid option: $opt"
      exit 1
      ;;
  esac
done

function is_created () {
  local container=$1
  docker ps -a --format '{{ .Names }}' | grep "$container" > /dev/null
  return $?
}

function is_up () {
  local container=$1
  docker inspect --format '{{ .State.Status }}' $container | grep "running" > /dev/null
  return $?
}

echo contrail-dev-env startup
echo
echo '[docker setup]'

distro=$(cat /etc/*release | egrep '^ID=' | awk -F= '{print $2}' | tr -d \")
echo $distro detected.
if [ x"$distro" == x"centos" ]; then
  which docker || yum install -y docker
  systemctl start docker
  systemctl stop firewalld || true
  systemctl start docker
  grep 'dm.basesize=20G' /etc/sysconfig/docker-storage || sed -i 's/DOCKER_STORAGE_OPTIONS=/DOCKER_STORAGE_OPTIONS=--storage-opt dm.basesize=20G /g' /etc/sysconfig/docker-storage
  systemctl restart docker
elif [ x"$distro" == x"ubuntu" ]; then
  which docker || apt install -y docker.io
fi

test "$setup_only" -eq 1 && exit

echo
echo '[environment setup]'
if [[ "$own_vm" -eq 0 ]]; then
  rpm_source=$(docker volume create --name contrail-dev-env-rpm-volume) 
else
  contrail_dir=$(realpath ${scriptdir}/../contrail)
  rpm_source=${contrail_dir}/RPMS
  mkdir -p ${rpm_source}
fi
echo "${rpm_source} created."

if ! is_created "contrail-dev-env-rpm-repo"; then
  docker run --privileged --name contrail-dev-env-rpm-repo \
    -d -p 6667:80 \
    -v ${rpm_source}:/var/www/localhost/htdocs \
    sebp/lighttpd >/dev/null
  echo contrail-dev-env-rpm-repo created.
else
  if is_up "contrail-dev-env-rpm-repo"; then
    echo "contrail-dev-env-rpm-repo already running."
  else
    echo $(docker start contrail-dev-env-rpm-repo) started.
  fi
fi

export REGISTRY_HEALTH_HTTP_TIMEOUT="300s"
export REGISTRY_HEALTH_TCP_TIMEOUT="300s"
if ! is_created "contrail-dev-env-registry"; then
  docker run --privileged --name contrail-dev-env-registry -v `pwd`/config.yml:/etc/docker/registry/config.yml \
    -d -p $REGISTRY_PORT:5000 \
    registry:2 >/dev/null
  echo contrail-dev-env-registry created.
else
  if is_up "contrail-dev-env-registry"; then
    echo "contrail-dev-env-registry already running."
  else
    echo $(docker start contrail-dev-env-registry) started.
  fi
fi

if [[ "$own_vm" -eq 0 ]]; then
  if ! is_created "contrail-developer-sandbox"; then
    if [[ x"$DEVENVTAG" == x"latest" ]]; then
      docker pull ${IMAGE}:${DEVENVTAG}
    fi
    docker run --privileged --name contrail-developer-sandbox \
      -w /root -itd \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v ${rpm_source}:/root/contrail/RPMS \
      -v $(pwd):/root/contrail-dev-env \
      -v /root/contrail:/root/contrail \
      -v /root/src:/root/src \
      ${IMAGE}:${DEVENVTAG} >/dev/null
    echo contrail-developer-sandbox created.
  else
    if is_up "contrail-developer-sandbox"; then
      echo "contrail-developer-sandbox already running."
    else
      echo $(docker start contrail-developer-sandbox) started.
    fi
  fi
fi

echo
echo '[configuration update]'
rpm_repo_ip=$(docker inspect --format '{{ .NetworkSettings.Gateway }}' contrail-dev-env-rpm-repo)
registry_ip=${REGISTRY_IP}
if [ -z $registry_ip ]; then
  registry_ip=$(docker inspect --format '{{ .NetworkSettings.Gateway }}' contrail-dev-env-registry)
fi

sed -e "s/rpm-repo/${rpm_repo_ip}/g" -e "s/registry/${registry_ip}/g" -e "s/6666/${REGISTRY_PORT}/g" common.env.tmpl > common.env
sed -e "s/rpm-repo/${rpm_repo_ip}/g" -e "s/contrail-registry/${registry_ip}/g" -e "s/6666/${REGISTRY_PORT}/g" vars.yaml.tmpl > vars.yaml
sed -e "s/rpm-repo/${rpm_repo_ip}/g" -e "s/registry/${registry_ip}/g" dev_config.yaml.tmpl > dev_config.yaml
sed -e "s/registry/${registry_ip}/g" -e "s/6666/${REGISTRY_PORT}/g" daemon.json.tmpl > daemon.json

if [ x"$distro" == x"centos" ]; then
  if ! diff daemon.json /etc/docker/daemon.json; then 
    cp daemon.json /etc/docker/daemon.json
    systemctl restart docker
    docker start contrail-dev-env-rpm-repo contrail-dev-env-registry
    test "$own_vm" -eq 0 && docker start contrail-developer-sandbox
  fi
elif [ x"$distro" == x"ubuntu" ]; then
  diff daemon.json /etc/docker/daemon.json || (cp daemon.json /etc/docker/daemon.json && service docker reload)
fi

echo
echo '[READY]'
test "$own_vm" -eq 0 && echo "You can now connect to the sandbox container by using: $ docker attach contrail-developer-sandbox"

