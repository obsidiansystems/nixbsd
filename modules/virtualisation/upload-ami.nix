# Script that uploads a disk image to S3, imports it as an EBS snapshot, and
# registers a UEFI, ENA-enabled AMI from it. Runs on the build machine.
#
# The raw image is converted to a stream-optimized VMDK first: VM Import
# won't take a compressed raw file, but that VMDK subformat is deflated
# internally, so a mostly-empty image uploads as a fraction of its size.
#
# Every stage is skipped if its result already exists, so re-running is safe:
# an AMI with the target name is returned as is, a finished snapshot whose
# description is the target name is reused, and an S3 object of the right size
# is not uploaded again.
#
# Requires the `vmimport` service role in the target account, see
# https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
{
  lib,
  writeShellApplication,
  awscli2,
  jq,
  qemu-utils,
  image,
  imageName,
  architecture,
}:
let
  # The store hash of the image, so the default AMI name changes exactly when
  # the image does. Names must be unique per account and region.
  imageHash = lib.substring 0 8 (lib.removePrefix "/nix/store/" (toString image));
in
writeShellApplication {
  name = "upload-ami";
  runtimeInputs = [
    awscli2
    jq
    qemu-utils
  ];
  text = ''
    usage() {
      echo "usage: upload-ami --bucket <s3-bucket> [--region <region>] [--name <ami-name>] [--keep-s3]" >&2
      exit 1
    }

    bucket=
    region="''${AWS_REGION:-''${AWS_DEFAULT_REGION:-}}"
    name=${lib.escapeShellArg "${imageName}-${imageHash}"}
    keep_s3=

    while [ $# -gt 0 ]; do
      case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --region) region="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --keep-s3) keep_s3=1; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$bucket" ] || usage
    [ -n "$region" ] || { echo "no region given and AWS_REGION is unset" >&2; exit 1; }
    export AWS_REGION="$region"

    imageFile=${image}/${image.filename}
    key="$name.vmdk"

    amiId=$(aws ec2 describe-images --owners self --filters "Name=name,Values=$name" \
      --query 'Images[0].ImageId' --output text)
    if [ "$amiId" != None ]; then
      echo "AMI $name already registered" >&2
      echo "$amiId"
      exit 0
    fi

    snapshotId=$(aws ec2 describe-snapshots --owner-ids self \
      --filters "Name=description,Values=$name" "Name=status,Values=completed" \
      --query 'Snapshots[0].SnapshotId' --output text)

    if [ "$snapshotId" != None ]; then
      echo "reusing snapshot $snapshotId" >&2
    else
      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' EXIT
      vmdk="$tmpdir/$key"
      echo "converting $imageFile to compressed VMDK" >&2
      qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "$imageFile" "$vmdk"

      size=$(stat -c %s "$vmdk")
      if [ "$(aws s3api head-object --bucket "$bucket" --key "$key" --query ContentLength --output text 2>/dev/null)" = "$size" ]; then
        echo "s3://$bucket/$key already uploaded" >&2
      else
        echo "uploading $vmdk ($((size / 1024 / 1024)) MiB) to s3://$bucket/$key" >&2
        aws s3 cp "$vmdk" "s3://$bucket/$key"
      fi

      echo "importing snapshot" >&2
      taskId=$(aws ec2 import-snapshot \
        --description "$name" \
        --disk-container "Format=VMDK,UserBucket={S3Bucket=$bucket,S3Key=$key}" \
        --query ImportTaskId --output text)

      while true; do
        task=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$taskId" \
          --query 'ImportSnapshotTasks[0].SnapshotTaskDetail')
        status=$(jq -r .Status <<<"$task")
        case "$status" in
          completed) break ;;
          deleted|deleting)
            echo "snapshot import failed: $(jq -r .StatusMessage <<<"$task")" >&2
            exit 1
            ;;
          *)
            echo "  $status $(jq -r '.Progress // ""' <<<"$task")% $(jq -r '.StatusMessage // ""' <<<"$task")" >&2
            sleep 15
            ;;
        esac
      done
      snapshotId=$(jq -r .SnapshotId <<<"$task")
      echo "snapshot $snapshotId" >&2

      if [ -z "$keep_s3" ]; then
        aws s3 rm "s3://$bucket/$key"
      fi
    fi

    echo "registering AMI $name" >&2
    amiId=$(aws ec2 register-image \
      --name "$name" \
      --architecture ${lib.escapeShellArg architecture} \
      --virtualization-type hvm \
      --boot-mode uefi \
      --ena-support \
      --root-device-name /dev/sda1 \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$snapshotId,VolumeType=gp3,DeleteOnTermination=true}" \
      --query ImageId --output text)

    echo "$amiId"
  '';
}
