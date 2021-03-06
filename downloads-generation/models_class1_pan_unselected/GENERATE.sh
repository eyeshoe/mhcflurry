#!/bin/bash
#
# Train pan-allele MHCflurry Class I models. Supports re-starting a failed run.
#
set -e
set -x

DOWNLOAD_NAME=models_class1_pan_unselected
SCRATCH_DIR=${TMPDIR-/tmp}/mhcflurry-downloads-generation
SCRIPT_ABSOLUTE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR=$(dirname "$SCRIPT_ABSOLUTE_PATH")

mkdir -p "$SCRATCH_DIR"
if [ "$1" != "continue-incomplete" ]
then
    echo "Fresh run"
    rm -rf "$SCRATCH_DIR/$DOWNLOAD_NAME"
    mkdir "$SCRATCH_DIR/$DOWNLOAD_NAME"
else
    echo "Continuing incomplete run"
fi

# Send stdout and stderr to a logfile included with the archive.
LOG="$SCRATCH_DIR/$DOWNLOAD_NAME/LOG.$(date +%s).txt"
exec >  >(tee -ia "$LOG")
exec 2> >(tee -ia "$LOG" >&2)

# Log some environment info
echo "Invocation: $0 $@"
date
pip freeze
git status

mhcflurry-downloads fetch data_curated allele_sequences random_peptide_predictions

cd $SCRATCH_DIR/$DOWNLOAD_NAME

cp $SCRIPT_DIR/generate_hyperparameters.py .
python generate_hyperparameters.py > hyperparameters.yaml

GPUS=$(nvidia-smi -L 2> /dev/null | wc -l) || GPUS=0
echo "Detected GPUS: $GPUS"

PROCESSORS=$(getconf _NPROCESSORS_ONLN)
echo "Detected processors: $PROCESSORS"

if [ "$GPUS" -eq "0" ]; then
   NUM_JOBS=${NUM_JOBS-1}
else
    NUM_JOBS=${NUM_JOBS-$GPUS}
fi
echo "Num jobs: $NUM_JOBS"

export PYTHONUNBUFFERED=1

if [ "$1" != "continue-incomplete" ]
then
    cp $SCRIPT_DIR/generate_hyperparameters.py .
    python generate_hyperparameters.py > hyperparameters.yaml
fi

for kind in with_mass_spec no_mass_spec
do
    EXTRA_TRAIN_ARGS=""
    if [ "$1" == "continue-incomplete" ] && [ -d "models.${kind}" ]
    then
        echo "Will continue existing run: $kind"
        EXTRA_TRAIN_ARGS="--continue-incomplete"
    fi

    mhcflurry-class1-train-pan-allele-models \
        --data "$(mhcflurry-downloads path data_curated)/curated_training_data.${kind}.csv.bz2" \
        --allele-sequences "$(mhcflurry-downloads path allele_sequences)/allele_sequences.csv" \
        --pretrain-data "$(mhcflurry-downloads path random_peptide_predictions)/predictions.csv.bz2" \
        --held-out-measurements-per-allele-fraction-and-max 0.25 100 \
        --num-folds 4 \
        --hyperparameters hyperparameters.yaml \
        --out-models-dir models.${kind} \
        --worker-log-dir "$SCRATCH_DIR/$DOWNLOAD_NAME" \
        --verbosity 0 \
        --num-jobs $NUM_JOBS --max-tasks-per-worker 1 --gpus $GPUS --max-workers-per-gpu 1 \
        $EXTRA_TRAIN_ARGS
done

cp $SCRIPT_ABSOLUTE_PATH .
bzip2 -f "$LOG"
for i in $(ls LOG-worker.*.txt) ; do bzip2 -f $i ; done
RESULT="$SCRATCH_DIR/${DOWNLOAD_NAME}.$(date +%Y%m%d).tar.bz2"
tar -cjf "$RESULT" *
echo "Created archive: $RESULT"

# Split into <2GB chunks for GitHub
PARTS="${RESULT}.part."
# Check for pre-existing part files and rename them.
for i in $(ls "${PARTS}"* )
do
    DEST="${i}.OLD.$(date +%s)"
    echo "WARNING: already exists: $i . Moving to $DEST"
    mv $i $DEST
done
split -b 2000M "$RESULT" "$PARTS"
echo "Split into parts:"
ls -lh "${PARTS}"*

