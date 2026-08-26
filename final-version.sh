#!/bin/bash

# ==========================================================
# AIO llama.cpp launcher
# ==========================================================

# ==========================================================
# USER CONFIG
# ==========================================================

# External model configuration
CONFIG_FILE="./models/models.conf"

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
# Sampling presets
#
# The actual --temp/--top-p/--top-k/etc. values live in models.conf
# now (MODE_FLAGS associative array), keyed "family:mode". This is
# just a lookup with a safe fallback if a combo isn't defined there.
# ==========================================================

get_mode_flags()
{

    local FAMILY="$1"
    local MODE="$2"
    local KEY="${FAMILY}:${MODE}"


    if [[ -n "${MODE_FLAGS[$KEY]+set}" ]]
    then
        echo "${MODE_FLAGS[$KEY]}"
    else
        echo ""
    fi

}



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
# Ask which sampling mode to use for this model
# ==========================================================

choose_mode()
{

    local INDEX=$1


    local MODES_CSV="${MODEL_MODES[$INDEX]}"


    # No modes configured for this model -> no extra sampling flags.
    if [[ -z "$MODES_CSV" ]]
    then
        echo ""
        return
    fi


    IFS=',' read -r -a MODES_ARR <<< "$MODES_CSV"


    # Only one mode -> apply silently, no prompt.
    if [[ ${#MODES_ARR[@]} -le 1 ]]
    then
        echo "${MODES_ARR[0]}"
        return
    fi


    echo >&2
    echo "Select sampling mode for ${MODEL_NAMES[$INDEX]}:" >&2

    for m in "${!MODES_ARR[@]}"
    do
        echo "  $((m+1))) ${MODES_ARR[$m]}" >&2
    done


    local MODE_CHOICE
    read -r -p "Mode: " MODE_CHOICE >&2


    if ! [[ "$MODE_CHOICE" =~ ^[0-9]+$ ]] || (( MODE_CHOICE < 1 || MODE_CHOICE > ${#MODES_ARR[@]} ))
    then
        echo "Invalid choice, defaulting to '${MODES_ARR[0]}'." >&2
        echo "${MODES_ARR[0]}"
        return
    fi


    echo "${MODES_ARR[$((MODE_CHOICE-1))]}"

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
    FAMILY="${MODEL_FAMILY[$INDEX]}"


    local SELECTED_MODE
    SELECTED_MODE=$(choose_mode "$INDEX")


    # NOTE: this used to be named "MODE_FLAGS", which shadowed the
    # global associative array MODE_FLAGS declared in models.conf
    # (bash dynamic scoping means that shadow also applied inside
    # get_mode_flags(), which this function calls). That made every
    # lookup silently return empty, so mode selection never actually
    # changed the sampling flags. Renamed to avoid the collision.
    local SELECTED_FLAGS=""
    if [[ -n "$SELECTED_MODE" ]]
    then
        SELECTED_FLAGS=$(get_mode_flags "$FAMILY" "$SELECTED_MODE")
    fi


    echo
    echo "======================================"
    echo "Starting:"
    echo "$MODEL"

    if [[ -n "$SELECTED_MODE" ]]
    then
        echo "Mode: $SELECTED_MODE ($SELECTED_FLAGS)"
    fi

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



    if [[ -n "$SELECTED_FLAGS" ]]
    then
        # shellcheck disable=SC2206
        LLAMA_ARGS+=($SELECTED_FLAGS)
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
