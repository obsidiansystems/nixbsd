# Script that uploads a raw disk image to S3, imports it as an EBS snapshot,
# and registers a UEFI, ENA-enabled AMI from it. Runs on the build machine.
#
# Requires the `vmimport` service role in the target account, see
# https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
{
  lib,
  writeShellApplication,
  awscli2,
  jq,
  image,
  imageName,
  architecture,
}:
writeShellApplication {
  name = "upload-ami";
  runtimeInputs = [
    awscli2
    jq
  ];
  text = ''
    usage() {
      echo "usage: upload-ami --bucket <s3-bucket> [--region <region>] [--name <ami-name>] [--keep-s3]" >&2
      exit 1
    }

    bucket=
    region="''${AWS_REGION:-''${AWS_DEFAULT_REGION:-}}"
    name=${lib.escapeShellArg imageName}
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
    key="$name.img"

    echo "uploading $imageFile to s3://$bucket/$key" >&2
    aws s3 cp --no-progress "$imageFile" "s3://$bucket/$key"

    echo "importing snapshot" >&2
    taskId=$(aws ec2 import-snapshot \
      --description "$name" \
      --disk-container "Format=RAW,UserBucket={S3Bucket=$bucket,S3Key=$key}" \
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
