#!/bin/bash

# ==========================================================
# AIO llama.cpp launcher
# ==========================================================

# ==========================================================
# USER CONFIG
# ==========================================================

# External model configuration
CONFIG_FILE="./models.conf"

# llama-server location
LLAMA_SERVER="./llama-b10603/llama-server"

# Base model folder
MODELS_DIR="./models"

# GPU wake delay
WAKE_DELAY=5


# ==========================================================
# Runtime options
# ==========================================================

USE_TOOLS=true
PRESERVE_THINKING=true

PIDS=()


# ==========================================================
# Load model config
# ==========================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found:"
    echo "$CONFIG_FILE"
    exit 1
fi


source "$CONFIG_FILE"


if [[ ${#MODEL_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: No models found in config."
    exit 1
fi



# ==========================================================
# Cleanup
# ==========================================================

cleanup_monitors()
{

    echo
    echo "Stopping radeontop monitors..."


    pkill -f "radeontop -b 3" 2>/dev/null
    pkill -f "radeontop -b 4" 2>/dev/null
    pkill -f "radeontop -b 5" 2>/dev/null
    pkill -f "radeontop -b 6" 2>/dev/null


    for pid in "${PIDS[@]}"
    do
        if kill -0 "$pid" 2>/dev/null
        then
            kill "$pid" 2>/dev/null
        fi
    done


    PIDS=()

}


cleanup()
{
    cleanup_monitors
}


trap cleanup EXIT INT TERM



# ==========================================================
# Start GPU monitors
# ==========================================================

start_radeon_monitors()
{

    cleanup_monitors


    echo
    echo "Starting radeontop monitors..."


    for gpu in 3 4 5 6
    do

        gnome-terminal \
        --title="RADEON GPU$gpu" \
        -- bash -c "exec radeontop -b $gpu" &


        PIDS+=("$!")

    done


    echo "RADEON monitors started."

}



# ==========================================================
# Launch llama-server
# ==========================================================

launch_model()
{

    local INDEX=$1


    MODEL="${MODEL_NAMES[$INDEX]}"
    ARGS="${MODEL_ARGS[$INDEX]}"
    ENVIRONMENT="${MODEL_ENV[$INDEX]}"


    echo
    echo "======================================"
    echo "Starting:"
    echo "$MODEL"
    echo "======================================"


    start_radeon_monitors


    echo
    echo "Waiting ${WAKE_DELAY}s for GPUs..."
    sleep "$WAKE_DELAY"



    LLAMA_ARGS=()



    if [[ "$USE_TOOLS" == true ]]
    then
        LLAMA_ARGS+=(--tools all)
        echo "Tools: ENABLED"
    else
        echo "Tools: DISABLED"
    fi



    if [[ "$PRESERVE_THINKING" == true ]]
    then

        LLAMA_ARGS+=(
            --reasoning on
            --reasoning-preserve
        )

        echo "Thinking preservation: ENABLED"

    else

        echo "Thinking preservation: DISABLED"

    fi



    echo


    echo "Launching llama-server..."



    if [[ -n "$ENVIRONMENT" ]]
    then

        eval "$ENVIRONMENT" \
        systemd-run --user --scope \
        -p MemoryMax=8G \
        -p OOMPolicy=stop \
        -E RADV_PERFTEST=nogttspill \
        "$LLAMA_SERVER" \
        $ARGS \
        "${LLAMA_ARGS[@]}"

    else

        systemd-run --user --scope \
        -p MemoryMax=8G \
        -p OOMPolicy=stop \
        -E RADV_PERFTEST=nogttspill \
        "$LLAMA_SERVER" \
        $ARGS \
        "${LLAMA_ARGS[@]}"

    fi



    EXIT_CODE=$?


    echo
    echo "llama exited with code: $EXIT_CODE"


    cleanup_monitors


}



# ==========================================================
# MENU
# ==========================================================

while true
do

clear


echo "======================================"
echo "          AIO LLAMA LAUNCHER"
echo "======================================"


for i in "${!MODEL_NAMES[@]}"
do

    NUM=$((i+1))

    if [[ -n "${MODEL_DESCRIPTION[$i]}" ]]
    then
        echo "$NUM) ${MODEL_NAMES[$i]} - ${MODEL_DESCRIPTION[$i]}"
    else
        echo "$NUM) ${MODEL_NAMES[$i]}"
    fi

done



echo
echo "t) Toggle tools"

if [[ "$USE_TOOLS" == true ]]
then
    echo "   Tools: ENABLED"
else
    echo "   Tools: DISABLED"
fi



echo
echo "p) Toggle preserve thinking"

if [[ "$PRESERVE_THINKING" == true ]]
then
    echo "   Preserve thinking: ENABLED"
else
    echo "   Preserve thinking: DISABLED"
fi



echo
echo "0) Exit"

echo

read -r -p "Choice: " CHOICE



case "$CHOICE" in


t|T)

if [[ "$USE_TOOLS" == true ]]
then
    USE_TOOLS=false
else
    USE_TOOLS=true
fi

continue

;;



p|P)

if [[ "$PRESERVE_THINKING" == true ]]
then
    PRESERVE_THINKING=false
else
    PRESERVE_THINKING=true
fi

continue

;;



0)

exit 0

;;



*)

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]
then
    echo "Invalid choice"
    sleep 1
    continue
fi


INDEX=$((CHOICE-1))


if (( INDEX < 0 || INDEX >= ${#MODEL_NAMES[@]} ))
then
    echo "Invalid choice"
    sleep 1
    continue
fi


launch_model "$INDEX"


echo
read -p "Press Enter to return menu"


;;

esac


done
