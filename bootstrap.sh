#!/usr/bin/env bash

source /etc/profile
set -Eeo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(< "${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}

#usage: sql HOST USER PASS args
sql() {
  export PGPASSWORD="$3"
  psql -v ON_ERROR_STOP=1 -h "$1" -U "$2" "${@:4}"
  unset PGPASSWORD
}

peer1SQL() {
  sql "$REPLICATION_PEER1" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$@"
}

peer2SQL() {
  sql "$REPLICATION_PEER2" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$@"
}

setup_replication() {

  sleep 10

  file_env 'APP_USER' 'app'
  file_env 'APP_PASSWORD' 'password'
  file_env 'APP_DB' 'app'

  file_env 'POSTGRES_USER' 'postgres'
  file_env 'POSTGRES_PASSWORD' 'password'

  file_env 'REPLICATION_USER' 'bdrsync'
  file_env 'REPLICATION_PASSWORD' 'default'
  file_env 'REPLICATION_PEER1' ''
  file_env 'REPLICATION_PEER2' ''

  echo
  echo 'Setting up AVAPolos replication'
  echo

  echo "Enabling BDR on app database."
  peer1SQL --dbname="$APP_DB" <<<"CREATE EXTENSION btree_gist;"
  peer1SQL --dbname="$APP_DB" <<<"CREATE EXTENSION bdr;"

  peer2SQL --dbname="$APP_DB" <<<"CREATE EXTENSION btree_gist;"
  peer2SQL --dbname="$APP_DB" <<<"CREATE EXTENSION bdr;"

  echo "Creating replication users."
  peer1SQL <<<"CREATE USER $REPLICATION_USER superuser;"
  peer1SQL <<<"ALTER USER $REPLICATION_USER WITH LOGIN PASSWORD '$REPLICATION_PASSWORD';"

  peer2SQL <<<"CREATE USER $REPLICATION_USER superuser;"
  peer2SQL <<<"ALTER USER $REPLICATION_USER WITH LOGIN PASSWORD '$REPLICATION_PASSWORD';"

  echo "Creating BDR group."
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_group_create(
          local_node_name := '$REPLICATION_PEER1',
          node_external_dsn := 'host=$REPLICATION_PEER1 user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD'
  );"
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_node_join_wait_for_ready()"
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_nodes.node_status FROM bdr.bdr_nodes;"

  echo "Joining BDR group."
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_group_join(
    local_node_name := '$REPLICATION_PEER2',
    node_external_dsn := 'host=$REPLICATION_PEER2 user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD',
    join_using_dsn := 'host=$REPLICATION_PEER1 user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD'
  );"
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_node_join_wait_for_ready()"
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_nodes.node_status FROM bdr.bdr_nodes;"

  echo "Creating avapolos_sync table."
  peer1SQL --dbname="$APP_DB" <<<"CREATE TABLE avapolos_sync (
    id serial not null PRIMARY KEY,
    instancia char(4) not null,
    versao int not null,
    tipo char(1) not null,
    data timestamptz not null DEFAULT NOW(),
    moodle_user varchar(255) not null
  );"

  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.wait_slot_confirm_lsn(NULL, NULL)"
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.wait_slot_confirm_lsn(NULL, NULL)"

  echo "Checking if it was replicated."

  peer2SQL --dbname="$APP_DB" <<<"SELECT * FROM avapolos_sync;"

  if ! [[ -z "$(peer2SQL --dbname="$APP_DB" <<<"SELECT * FROM avapolos_sync;" | grep -o row)" ]]; then
    echo
    echo 'Replication set up successfully.'
    echo
  else
    echo
    echo 'Failed to set up replication.'
    echo
    exit 1
  fi
}

setup_replication