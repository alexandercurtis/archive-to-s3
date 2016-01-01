#!/bin/bash
# Script that compresses, encrypts and moves batch files up to S3

default_batch_files_path="/var/www/shared/batch-files"
valid_suppliers=( supplier1 supplier2 supplier3 supplier4 )
default_bcrypt_password="password" # Leave blank to skip encryption
date_file_name=".last-archive-date"

# Prevent erroneous behaviour on empty directories
shopt -s nullglob

function usage {
  cat <<EOF
Usage:
  ${0##*/} [--auto | --before <YYYY-MM-DD>] [--from <YYYY-MM-DD>] [--bcrypt <passphrase>] [--path <path-to-batch-files>] [--noupload] [--delete]

  --auto
       Automatic archiving. Archives all batch files since last invocation. (Tracks the last invocation date in a file ".last-archive-date" in the <path-to-batch-files> directory.)

  --before <YYYY-MM-DD>
       Manual archiving. Specifies the date before which files will be archived.

  --from <YYYY-MM-DD>
       Manual archiving. Specifies a data before which files will not be archived. (Must fall before the date specified with --before.)

  --bcrypt <passphrase>
       if present, will encrypt the tarred batch files using bcrypt with the passphrase given.

  --path <path-to-batch-files>
       specifies the directory containing the batch files (i.e the directory with all the supplier folders in it.)

  --noupload
       prevents uploading to Amazon S3 (probably only useful for debugging.) Default is to upload.

  --delete
       deletes the batch files locally once they have been uploaded to S3

EOF
}

function usage_hint {
  echo
  echo "Use \`${0##*/} --help\` for help."
}

function zip_up {
  basename=${1##*/}
  dirname=${1%/*}
  tar -cjC $dirname -f $2 $basename
}

function encrypt {
  if [[ ! "$1.bfe" = "$2" ]]
  then
    echo "bcrypt won't let you specify a destination file. It has to be <source_file>.bfe"
    exit 1
  fi
  echo -e "${3}\n${3}\n" | bcrypt -s0 $1 2> /dev/null
}

function copy_to_s3 {
  s3cmd put ${1} s3://energy-batch-files/$2/
}

while [[ $# -ge 1 ]]
do
key="$1"
shift

case $key in
    -a|--auto)
      auto=1
    ;;
    -p|--path)
      batch_files_path="$1"
      shift
    ;;
    -b|--before)
      cutoff_date="$1"
      shift
    ;;
    -f|--from)
      earliest_date="$1"
      shift
    ;;
    -p|--bcrypt)
      password="$1"
      shift
    ;;
    -n|--noupload)
      upload=0
    ;;
    --delete)
      delete=1
    ;;
    -h|--help)
      usage
      exit 0
    ;;
    *)
      echo "Unknown option $key"
      usage
      exit 1
    ;;
esac
done


# Assign default values to variables not set on command line
: ${batch_files_path:=$default_batch_files_path}
: ${upload:=1}
: ${delete:=0}
: ${password:=$default_bcrypt_password}
: ${auto:=0}
today=$(date +%Y-%m-%d)
last_date_file_name=${batch_files_path}/${date_file_name}

if [[ $auto = 1 ]]; then
  if [[ ! -z $cutoff_date ]] || [[ ! -z $earliest_date ]]; then
    echo "Please don't specify --before or --from when specifying --auto."
    usage_hint
    exit 1
  fi
  if [[ -e ${last_date_file_name} ]]; then
    earliest_date=$(<${last_date_file_name})
  fi
  cutoff_date=$today
fi

if [[ -z $cutoff_date ]]; then
  echo "Please supply a cutoff date, for example:"
  echo "$0 --before 2014-09-10"
  usage_hint
  exit 1
fi

# Ensure s3cmd is installed if we are going to be uploading to S3
if [[ $upload = 1 ]]; then
  command -v s3cmd >/dev/null 2>&1 || { echo >&2 "s3cmd is not on path. Please ensure that s3cmd is installed."; exit 1; }
fi

# Ensure cutoff date is in correct format.
if [[ ! $cutoff_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Please give the cutoff date in the format YYYY-MM-DD, for example:"
  echo "$0 --before 2014-09-10"
  usage_hint
  exit 1
fi

if [[ ! -z $earliest_date ]]; then
  if [[ ! $earliest_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Please give the 'from' date in the format YYYY-MM-DD, for example:"
    echo "$0 --from 2013-12-31"
    usage_hint
    exit 1
  fi
fi

# Ensure password is ok
if [[ ! -z $password ]]; then
  if [[ ${#password} -le 8 ]] || [[ ${#password} -gt 56 ]]; then
    echo "bcrypt passwords must be between 8 and 56 characters long."
    exit 1
  fi
fi

# Don't allow today as a cutoff (to avoid archiving stuff that is in the middle of being created).
if [[ $cutoff_date > $today ]]; then
  echo "Cutoff date must not be in the future, for example:"
  echo "$0 --before 2014-09-10"
  echo "(This is to avoid trying to archive files that are still being created.)"
  usage_hint
  exit 1
fi

# Announce what we're about to do.
now=$(date "+%Y-%m-%d %H:%M:%S")
echo -n "${now} Archiving files in ${batch_files_path}"
if [[ ! -z $earliest_date ]]; then
  echo -n " from ${earliest_date} until"
else
  echo -n " before"
fi
echo " ${cutoff_date}..."


# Main loop
for supplier_dir in $batch_files_path/*
do
  supplier_key=${supplier_dir##*/}

  valid=0
  for valid_supplier in "${valid_suppliers[@]}"; do
    if [[ $supplier_key = $valid_supplier ]]; then
      valid=1
    fi
  done

  if [[ $valid = 1 ]]; then
    temp_dir=$(mktemp -dt "archived-${supplier_key}.XXXXXXXX")
    for batch_file_dir in $supplier_dir/*
    do
      batch_date=${batch_file_dir##*/}
      if [[ $batch_date < $cutoff_date ]]
      then
        if [[ -z $earliest_date ]] || [[ ! $batch_date < $earliest_date ]]; then
          echo "$supplier_key/$batch_date"
          basefile="${temp_dir}/${supplier_key}-${batch_date}"

          zipfile="${basefile}.tar.bz2"
          zip_up $batch_file_dir $zipfile

          if [[ -z $password ]]; then
            cryptfile=$zipfile
          else
            cryptfile="${zipfile}.bfe"
            encrypt $zipfile $cryptfile $password
          fi

          if [[ $upload = 1 ]]; then
            copy_to_s3 $cryptfile $supplier_key
            if [[ $? -eq 0 ]] && [[ $delete -eq 1 ]]; then
              rm -rf $batch_file_dir
            fi
          fi
        fi
      fi
    done

    if [[ $upload = 1 ]]; then
      rm -r $temp_dir
    else
      echo "${supplier_key} files are in ${temp_dir}"
    fi

  else
    echo "WARNING: Ignoring \"${supplier_key}\" as it is not a known supplier. (Have you specified the correct batch files path?)"
  fi

done

# Record the date the archive was done, ready for next time
if [[ $auto = 1 ]]; then
  echo $cutoff_date > ${last_date_file_name}
fi
