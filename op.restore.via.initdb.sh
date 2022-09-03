#!/bin/bash

# Postgres Restore script from Google Cloud bucket

set -e

echo "op.restore"
printf "[INFO]: You can use this script like this: ./op.restore.sh <bucket-name> <file-path-in-bucket> <db-password> <db-user> <os-user (optional, 'postgres' if not specified)> <os-usergroup (optional, same as os-user if not specified)>\n  ^This message is not an error, but rather a hard-coded documentation\n"
BACKUP_BUCKET_NAME="${1:?Expecting the source bucket name as the 1st arg}"
FILE_PATH_IN_BUCKET="${2:?Expecting the source file path in bucket as the 2nd arg}"
DB_PASS="${3:?Expecting postgres password as 3rd arg}"
DB_USER="${4:?Expecting db user as the 4th arg (for example, postgres if using the default one)}"
OS_USER="${5:-postgres}"
OS_USER_GROUP="${6:-$OS_USER}"
BACKUP_PREPROCESSED_FILE_NAME='latest_preprocessed.sql'
RESTORES_DIR="/var/lib/dbrestorelogs"
RESTORE_LOG_FILE_PATH="$RESTORES_DIR/$(date -u +"%d-%m-%Y %H-%M-%S").log"
PSQL_PATH="/usr/local/bin/psql"

if [[ ! -f "$PSQL_PATH" ]]; then
    PSQL_PATH=$(which psql)
fi

if [[ ! -f "$PSQL_PATH" ]]; then
    echo "psql command not found. Exiting..." >&2
    exit 1
fi

mkdir -p "$RESTORES_DIR"
# Commented: only postgres needs access to this
# chmod 777 "$RESTORES_DIR"
echo "Setting '$OS_USER' as owner of '$RESTORES_DIR'"
chown "$OS_USER":"$OS_USER_GROUP" "$RESTORES_DIR"

wd="$(mktemp -d)"
cd "$wd"
echo "Working directory: $wd"
echo "Setting '$OS_USER' as owner of '$wd'"
# Commented: only postgres needs access to this
# chmod 777 "$wd"
chown "$OS_USER":"$OS_USER_GROUP" "$wd"

echo "Retrieving default service account token"
# Thanks https://medium.com/@sachin.d.shinde/docker-compose-in-container-optimized-os-159b12e3d117
TOKEN=$(curl --fail "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" -H "Metadata-Flavor: Google")
TOKEN=$(echo "$TOKEN" | grep --extended-regexp --only-matching "(ya29.[0-9a-zA-Z._-]*)")
file_path_in_bucket_urlencoded=$(printf %s "$FILE_PATH_IN_BUCKET"|jq -sRr @uri)
echo "Downloading $FILE_PATH_IN_BUCKET via REST"
backup_filename=$(basename "${FILE_PATH_IN_BUCKET}")
curl -X GET \
    --fail \
    -H "Authorization: Bearer $TOKEN" \
    -o "$backup_filename" \
    "https://www.googleapis.com/storage/v1/b/$BACKUP_BUCKET_NAME/o/$file_path_in_bucket_urlencoded?alt=media"

set_postgres_user_pw(){
    # Commented: if running on Alpine, sudo is not available and actually not needed
    # sudo -Hiu "$OS_USER" psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
    su "$OS_USER" -s "$PSQL_PATH" -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
}


echo "Backing up hba conf and postgresql conf files before potentially re-initializing cluster"
# Commented: doesn't work if db server is stopped
## Lazy approach to return a non-existing directory, if the first command fails
# psql_conf_dir="$(su "$OS_USER" -c """$PSQL_PATH"" -tA -c 'SHOW data_directory;'" || echo 012364982748927394612473909)"
psql_conf_dir="$(pg_config --bindir)"
psql_conf_dir="${psql_conf_dir%bin}data"
if [[ -d "$psql_conf_dir" ]]; then
    hba_conf_file=$"$psql_conf_dir/pg_hba.conf"
    postgresql_conf_file=$"$psql_conf_dir/postgresql.conf"
    hba_conf_file_bak=$(mktemp)
    postgresql_conf_file_bak=$(mktemp)
    cp "$hba_conf_file" "$hba_conf_file_bak"
    cp "$postgresql_conf_file" "$postgresql_conf_file_bak"
    
    echo "Checking if server is running.."
    sv_status_text="$(su """$OS_USER""" -c "pg_ctl status || echo err")"
    if [[ "$sv_status_text" == *"pg_ctl: server is running"* ]]; then
        echo "Stopping server"
        su "$OS_USER" -c "pg_ctl -D ""$psql_conf_dir"" stop"
    fi

    # echo "Setting 'postgres' user's pw"
    # set_postgres_user_pw
else
    echo "postgresql not found at $psql_conf_dir. Skipping backing up hba conf and postgres conf"
    psql_conf_dir="/usr/local/pgsql/data"
fi

if [[ -d "$psql_conf_dir" ]]; then
    echo "$psql_conf_dir already exists. It'll be deleted in 5 sec.."
    sleep 5
    rm -rf "$psql_conf_dir"
fi
echo "Initializing new cluster via 'initdb' at $psql_conf_dir"
mkdir -p "$psql_conf_dir"
chown "$OS_USER":"$OS_USER_GROUP" "$psql_conf_dir"
su "$OS_USER" -c "initdb -D ""$psql_conf_dir"" -E UNICODE --locale=C"


if [[ -z "$hba_conf_file_bak" ]]; then
    echo "No hba conf and postgresql conf files were backed up, probably because there was no cluster active, so there's nothing to restore. Most probably, you'll need to setup hba and postgres config files manually"
else
    # Note that in some setups dtopping the cluster doesn't actually remove these. This was found during working with a postgres installed from source
    echo "Restoring up hba conf and postgresql conf files before starting the new cluster"
    cp "$hba_conf_file_bak" "$hba_conf_file"
    cp "$postgresql_conf_file_bak" "$postgresql_conf_file"
fi

su "$OS_USER" -c "pg_ctl -D ""$psql_conf_dir"" -l ""$psql_conf_dir""/logfile start"

# Commented: we'll reinit the whole db
# drop_cmd="SELECT 'dropdb '||datname||'' FROM pg_database WHERE datistemplate = false AND datallowconn = true And datname NOT IN ('postgres')"
# su "$OS_USER" -c "$PSQL_PATH -c ""$drop_cmd"" |grep ' dropdb ' |  sudo -u postgres /bin/bash ; cd"

echo "Removing the instruction for creating the 'postgres' role as the cluster might already have it"
# Inside the backup file, remove the command that creates the postgres role, because the default
# installation of postgresql might already have it. Source: https://dba.stackexchange.com/a/176562
grep -E -v '^(CREATE|DROP) ROLE( IF EXISTS)* postgres;' "$backup_filename" > "$BACKUP_PREPROCESSED_FILE_NAME"


# echo "Prepending commands to the restore script to recreate the current schema, including grants"
# delete_everything_command="
# -- Automatically added by op.restore.sh script to clear previous data
# DROP SCHEMA public CASCADE;
# CREATE SCHEMA public;
# GRANT ALL ON SCHEMA public TO $DB_USER;
# GRANT ALL ON SCHEMA public TO public;
# --

# "
# tmp_file_clean_commands=$(mktemp)
# tmp_file_restore_commands=$(mktemp)
# echo "$delete_everything_command" > "$tmp_file_clean_commands"
# cp "$BACKUP_PREPROCESSED_FILE_NAME" "$tmp_file_restore_commands"
# cat "$tmp_file_clean_commands" "$tmp_file_restore_commands" > $BACKUP_PREPROCESSED_FILE_NAME


echo "Restoring from $BACKUP_PREPROCESSED_FILE_NAME"
# Calling the restore command of postgresql. This requires us to use the postgres user instead of root
# Source: https://www.opsdash.com/blog/postgresql-backup-restore.html
# Source for -Hiu args: https://dba.stackexchange.com/a/226882
#   Otherwise, if we use only -u, we get permission denied error for entering current dir
set +e
# Commented: if running on Alpine, sudo is not available and actually not needed
# sudo -Hiu "$OS_USER" PGOPTIONS='--client-min-messages=warning' \
export PGOPTIONS='--client-min-messages=warning'
su "$OS_USER" -c "$PSQL_PATH -X -q -v ON_ERROR_STOP=1 --pset pager=off -f '$BACKUP_PREPROCESSED_FILE_NAME' -L '$RESTORE_LOG_FILE_PATH'"
code="$?"
set -e

if [ $code != 0 ]; then
    echo "Restore error. Displaying restore log and exiting..."
    sleep 1
    cat "$RESTORE_LOG_FILE_PATH"
    echo ""
    exit $code
else
    echo "Done restoring. Restore log can be found at $RESTORE_LOG_FILE_PATH"
fi

echo "Setting 'postgres' user's pw"
set_postgres_user_pw

echo "Done!"
