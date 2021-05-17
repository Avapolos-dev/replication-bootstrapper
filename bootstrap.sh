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

file_env 'APP_USER' 'app'
file_env 'APP_PASSWORD' 'password'
file_env 'APP_DB' 'app'

file_env 'POSTGRES_USER' 'postgres'
file_env 'POSTGRES_PASSWORD' 'password'

file_env 'REPLICATION_USER' 'bdrsync'
file_env 'REPLICATION_PASSWORD' 'default'
file_env 'REPLICATION_MAIN' ''
file_env 'REPLICATION_SYNC' ''

# $1 -> host
wait_for_db() {
  until pg_isready -h "$1"; do
    sleep 1
  done
}

#usage: sql HOST USER PASS args
sql() {
  export PGPASSWORD="$3"
  psql -v ON_ERROR_STOP=1 -h "$1" -U "$2" "${@:4}"
  unset PGPASSWORD
}

peer1SQL() {
  sql "$REPLICATION_MAIN" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$@"
}

peer2SQL() {
  sql "$REPLICATION_SYNC" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$@"
}

is_replication_working() {
  echo
  echo "Testing replication."
  echo

  wait_for_db "$REPLICATION_MAIN"
  wait_for_db "$REPLICATION_SYNC"

  if ! peer2SQL --dbname="$APP_DB" <<<"SELECT * FROM sync_test;" | grep -q row; then
    echo "Test table does not exist, replication is definetly not working."
    return 1
  fi
  
  num=$RANDOM
  echo "Random number generated: $num"

  echo "Inserting into main-db."
  peer1SQL --dbname="$APP_DB" <<<"INSERT INTO sync_test(num) VALUES ($num);"
  echo "Waiting for replication to be done."
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.wait_slot_confirm_lsn(NULL, NULL)"

  echo "Checking if it was replicated."
  peer2SQL --dbname="$APP_DB" <<<"SELECT * FROM sync_test;"

  if ! peer2SQL --dbname="$APP_DB" <<<"SELECT * FROM sync_test;" | grep -q $num; then
    return 1
  else
    return 0
  fi
}

setup_replication() {

  echo
  echo 'Setting up AVAPolos replication'
  echo

  wait_for_db "$REPLICATION_MAIN"
  wait_for_db "$REPLICATION_SYNC"

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
          local_node_name := '$REPLICATION_MAIN',
          node_external_dsn := 'host=$REPLICATION_MAIN user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD'
  );"
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_node_join_wait_for_ready()"
  peer1SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_nodes.node_status FROM bdr.bdr_nodes;"

  echo "Joining BDR group."
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_group_join(
    local_node_name := '$REPLICATION_SYNC',
    node_external_dsn := 'host=$REPLICATION_SYNC user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD',
    join_using_dsn := 'host=$REPLICATION_MAIN user=$REPLICATION_USER dbname=$APP_DB password=$REPLICATION_PASSWORD'
  );"
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_node_join_wait_for_ready()"
  peer2SQL --dbname="$APP_DB" <<<"SELECT bdr.bdr_nodes.node_status FROM bdr.bdr_nodes;"

  peer1SQL --dbname="$APP_DB" <<<"CREATE TABLE sync_test (
    id serial not null PRIMARY KEY,
    num int not null
  );"
}

main() {
  if is_replication_working; then
    echo
    echo "Replication is already working, skipping."
    echo
  else
    echo "Replication is not working, configuring."
    setup_replication

    if ! is_replication_working; then
      echo
      echo "Replication is still not working after configuring"
      echo
      exit 1
    fi

    echo
    echo "Replication is working."
    echo
    exit 0
  fi
}

main
