#!/bin/bash


##################################
# Usage and Arguments Processing #
##################################

usage="$(basename "$0") client-folder-name [push|pull] [files|db|all] [-h] [-s] -- program to up and download wordpress files and database

If a config file (.deployment-config) is found in the project folder, these values will be used. Option flags override config file values.

usage:
  Upload files and database to remote server
  $(basename "$0") client-folder-name push all 

  Upload only files to remote server
  $(basename "$0") client-folder-name push files 

  Download files and database from remote server
  $(basename "$0") client-folder-name pull all 

options:
  -h  show this help text
  -D  Dry run, just display the configuration settings

  URL configuration
  -l  Project local URL i.e http://client.localdev
  -r  Project remote URL i.e https://client.com
  
  Remote server connection:
  -u  User name
  -H  Host
  -p  Port
  -f  Path to WordPress install

config file sample:
  PROJECT_LOCAL_URL=http://client.localdev
  PROJECT_REMOTE_URL=https://client.com
  REMOTE_USER=username
  REMOTE_HOST=host.com
  REMOTE_PORT=1234 
  REMOTE_PATH=/var/www/wp/
  #END

"

#ARGS
DRY_RUN=0

#Project
if [ -z "$1" ]; then
  echo 'Project name has to be set: i.e. $ wp-deployment.sh client-folder-name';
  exit 1
else 
  PROJECT_NAME=${1}
fi
#Direction
if [ -z "$2" ]; then
  #Default to push
  #ACT_DIR='push'
  echo 'Specify direction: i.e. $ wp-deployment.sh client-folder-name push[pull]';
  exit 1
else 
  ACT_DIR=${2}
fi
#DB/Files
if [ "$3" = "files" ]; then
  ACT_DB=0
  ACT_FILES=1
elif [ "$3" = "db" ]; then
  ACT_DB=1
  ACT_FILES=0
elif [ "$3" = "all" ]; then
  ACT_DB=1
  ACT_FILES=1
else
  echo 'Specify files, db, all: i.e. $ wp-deployment.sh client-folder-name push[pull] [files|db|all]';
  exit 1
fi

shift 3

PROJECT=$(echo $PROJECT_NAME | sed -e 's/[^A-Za-z0-9._-]//g')
PROJECT_PATH='./'$PROJECT'/'



##################################
# Read from config file          #
##################################

#Defaults, overwritten by config file
PROJECT_LOCAL_URL=''
PROJECT_REMOTE_URL=''
REMOTE_USER=''
REMOTE_HOST=''
REMOTE_PORT='' 
REMOTE_PATH=''

CONFIG_FILE=$PROJECT_PATH'.deployment-config'

if [ -f $CONFIG_FILE ]; then
  IFS="="
  while read -r name value
  do
    config_name="$(echo -e "${name}" | tr -d '[:space:]')"
    config_value="$(echo -e "${value}" | tr -d '[:space:]')"
    case $config_name in
      PROJECT_LOCAL_URL)
        PROJECT_LOCAL_URL=$config_value
        ;;
      PROJECT_REMOTE_URL)
        PROJECT_REMOTE_URL=$config_value
        ;;
      REMOTE_USER)
        REMOTE_USER=$config_value
        ;;
      REMOTE_HOST)
        REMOTE_HOST=$config_value
        ;;
      REMOTE_PORT)
        REMOTE_PORT=$config_value
        ;;
      REMOTE_PATH)
        REMOTE_PATH=$config_value
        ;;
     *)
        echo 'Config variable not used: ' $config_name $value
        ;;
    esac
  done < $CONFIG_FILE
else
  CONFIG_FILE='\x1B[1;31mnot found\x1B[0m'
fi


#Get Args
while getopts ':hl::r::u::H::p::f::D:' option; do
  case "$option" in
    h) echo "$usage"
       exit
       ;;
    l) PROJECT_LOCAL_URL=$OPTARG
       ;;
    r) PROJECT_REMOTE_URL=$OPTARG
       ;;
    u) REMOTE_USER=$OPTARG
       ;;
    H) REMOTE_HOST=$OPTARG
       ;;
    p) REMOTE_PORT=$OPTARG
       ;;
    f) REMOTE_PATH=$OPTARG
       ;;
    :) 
      if [ "$OPTARG" != "D" ]; then
        printf "missing argument for -%s\n" "$OPTARG" >&2
        echo "$usage" >&2
        exit 1
      else
        DRY_RUN=1
      fi
      ;;
   \?) printf "illegal option: -%s\n" "$OPTARG" >&2
       echo "$usage" >&2
       exit 1
       ;;
  esac
done
shift $((OPTIND - 1))

echo -e "

\x1B[1;34mUsing the following config:\x1B[0m
config file $CONFIG_FILE

  Database:  $ACT_DB 
  Files:     $ACT_FILES
  Direction: $ACT_DIR 

  Local URL:  $PROJECT_LOCAL_URL
  Remote URL: $PROJECT_REMOTE_URL

  User: $REMOTE_USER 
  Path: $REMOTE_PATH 
  Host: $REMOTE_HOST 
  Port: $REMOTE_PORT

"

#Paths
REMOTE_WP_PATH=$REMOTE_PATH
DBDUMP_TMP=$PROJECT'_'$(date +"%Y%m%d_%H%M%S")'.sql'

#Check Input Data
if [ -z "$PROJECT_LOCAL_URL" ]; then
  echo -e '\x1B[1;31mPROJECT_LOCAL_URL\x1B[0m is not set -l';
  exit 1
fi

if [ -z "$PROJECT_REMOTE_URL" ]; then
  echo -e '\x1B[1;31mPROJECT_REMOTE_URL\x1B[0m is not set -r';
  exit 1
fi

if [ -z "$REMOTE_USER" ]; then
  echo -e '\x1B[1;31mREMOTE_USER\x1B[0m is not set -u';
  exit 1
fi

if [ -z "$REMOTE_PATH" ]; then
  echo -e '\x1B[1;31mREMOTE_PATH\x1B[0m is not set -f';
  exit 1
fi

if [ -z "$REMOTE_HOST" ]; then
  echo -e '\x1B[1;31mREMOTE_HOST\x1B[0m is not set -H';
  exit 1
fi

if [ -z "$REMOTE_PORT" ]; then
  echo -e '\x1B[1;31mREMOTE_PORT\x1B[0m is not set -p';
  exit 1
fi

#Dry run output
if [ $DRY_RUN = '1' ]; then
  echo -e '\x1B[1;30mDRY RUN\x1B[0m'
  echo ''
  exit 1;
fi


##################################
# Database                       #
##################################

function db_upload {
  echo -e "\x1B[1;32mDatabase Actions UP\x1B[0m"

  #WP Config 
  WPDB_LOCAL_NAME=`cat $PROJECT_PATH'wp-config.php' | grep DB_NAME | cut -d \' -f 4`
  WPDB_LOCAL_USER=`cat $PROJECT_PATH'wp-config.php' | grep DB_USER | cut -d \' -f 4`
  WPDB_LOCAL_PASS=`cat $PROJECT_PATH'wp-config.php' | grep DB_PASSWORD | cut -d \' -f 4`
  WPDB_LOCAL_HOST=`cat $PROJECT_PATH'wp-config.php' | grep DB_HOST | cut -d \' -f 4`

  if [ -z "$WPDB_LOCAL_NAME" -a "$WPDB_LOCAL_NAME" != " " ] || [ -z "$WPDB_LOCAL_USER" -a "$WPDB_LOCAL_USER" != " " ] || [ -z "$WPDB_LOCAL_PASS" -a "$WPDB_LOCAL_PASS" != " " ]; then
    echo 'Local DB config not defined, got DB: '$WPDB_LOCAL_NAME' USER: '$WPDB_LOCAL_USER' PASS: '$WPDB_LOCAL_PASS 
    exit 1  
  fi

  if [ -z "$WPDB_LOCAL_HOST" -a "$WPDB_LOCAL_HOST" != " " ]; then
    WPDB_LOCAL_HOST_ARG=' -h ' $WPDB_LOCAL_HOST
  else
    WPDB_LOCAL_HOST_ARG=''
  fi

  #Get DBDump
  mysqldump -u $WPDB_LOCAL_USER -p$WPDB_LOCAL_PASS $WPDB_LOCAL_HOST_ARG $WPDB_LOCAL_NAME > $DBDUMP_TMP

  #Upload DBDump to Server
  rsync -avz -e "ssh -p$REMOTE_PORT" $DBDUMP_TMP $REMOTE_USER'@'$REMOTE_HOST':'$REMOTE_PATH

  #Remove local DBDump
  rm $DBDUMP_TMP

  #Read remote DB Connection settings
  REMOTE_WP_CONF_TMP='remote_wp_config_'$PROJECT'.sql'
  rsync -avz -e "ssh -p$REMOTE_PORT" $REMOTE_USER'@'$REMOTE_HOST':'$REMOTE_WP_PATH'wp-config.php' $REMOTE_WP_CONF_TMP

  #Remote WP Config
  WPDB_REMOTE_NAME=`cat $REMOTE_WP_CONF_TMP | grep DB_NAME | cut -d \' -f 4`
  WPDB_REMOTE_USER=`cat $REMOTE_WP_CONF_TMP | grep DB_USER | cut -d \' -f 4`
  WPDB_REMOTE_PASS=`cat $REMOTE_WP_CONF_TMP | grep DB_PASSWORD | cut -d \' -f 4`
  WPDB_REMOTE_HOST=`cat $REMOTE_WP_CONF_TMP | grep DB_HOST | cut -d \' -f 4`

  rm $REMOTE_WP_CONF_TMP

  if [ -z "$WPDB_REMOTE_HOST" -a "$WPDB_REMOTE_HOST" != " " ]; then
    WPDB_REMOTE_HOST_ARG=' -h ' $WPDB_REMOTE_HOST
  else
    WPDB_REMOTE_HOST_ARG=''
  fi

  ssh -p$REMOTE_PORT $REMOTE_USER'@'$REMOTE_HOST <<EOT
    mysql -u $WPDB_REMOTE_USER -p$WPDB_REMOTE_PASS $WPDB_REMOTE_HOST_ARG $WPDB_REMOTE_NAME <  $REMOTE_PATH$DBDUMP_TMP
    wp search-replace --path=$REMOTE_WP_PATH '$PROJECT_LOCAL_URL' '$PROJECT_REMOTE_URL'
    rm $REMOTE_PATH$DBDUMP_TMP
EOT

  return 0;
}


function db_download {
  echo -e "\x1B[1;32mDatabase Actions DOWN\x1B[0m"
  echo ' NOT YET IMPLEMENTED '
  return 0;
}


if [ $ACT_DB = '1' ]; then
  if [ $ACT_DIR = 'push' ]; then
    db_upload
  elif [ $ACT_DIR = 'pull' ]; then
    db_download
  fi
fi



##################################
# Files                          #
##################################

function files_upload {
  echo -e "\x1B[1;32mFile Actions UP\x1B[0m"
  rsync -avz -e "ssh -p2121" --exclude 'wp-config.php' --exclude '.git' --exclude '.gitignore' --exclude 'wp-content/cache' --exclude '*node_modules*' --exclude '.deployment' --exclude '.htaccess' $PROJECT_PATH $REMOTE_USER'@'$REMOTE_HOST':'$REMOTE_PATH
  return 0;
}


function files_download {
  echo -e "\x1B[1;32mFile Actions DOWN\x1B[0m"
  echo ' NOT YET IMPLEMENTED '
  #TODO
  return 0;
}


if [ $ACT_FILES = '1' ]; then
  if [ $ACT_DIR = 'push' ]; then
    files_upload
  elif [ $ACT_DIR = 'pull' ]; then
    files_download
  fi
fi

