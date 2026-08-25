#!/bin/bash

# ==========================================================
# AIO llama.cpp launcher
# ==========================================================

# ==========================================================
# USER CONFIG
# ==========================================================

# External model configuration
CONFIG_FILE="./claude-models.conf"

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
# Sources (checked against the actual model cards, not guessed):
#
#  - qwen36 (Nail, Hermes): straight from Qwen/Qwen3.6-35B-A3B's
#    own "Best Practices" section on Hugging Face. Nail/Hermes are
#    Uncensored-Genesis merges built on this base and their own
#    cards don't publish overrides, so the base model's numbers
#    are the right fallback.
#      code     -> "thinking mode, precise coding (e.g. WebDev)"
#      general  -> "thinking mode, general tasks"
#      instruct -> official "non-thinking" mode
#      creative -> NOT an official Qwen preset. Heuristic: nudge
#                  temp + presence_penalty up from "general" for
#                  longer-form / roleplay-style output. Treat as a
#                  starting point to tune, not a sourced number.
#
#  - qwen36-compact: same base model/numbers, just kept to 2 modes
#    since these builds are used for a narrow task (prompt gen).
#
#  - ornith: deepreinforce-ai/Ornith-1.0-35B. This is a DIFFERENT
#    model from Nail/Hermes (own finetune, own weights), confirmed
#    via its model card and independently by every quant mirror
#    (unsloth, protoLabsAI, ansulev's uncensored fork all cite the
#    same numbers):
#      code    -> temp=0.6, top_p=0.95, top_k=20 (the model's one
#                 documented default - it's already coding-tuned)
#      general -> temp=1.0, top_p=1.0 (the higher-temp setting
#                 Ornith's own Terminal-Bench/agentic evals used)
#
#  - gptoss: llama.cpp's official gpt-oss guide states the
#    recommended setting is exactly `--temp 1.0 --top-p 1.0`
#    (OpenAI didn't publish a per-task split for this model).
#      general -> the official 1.0/1.0 setting
#      code    -> NOT official. Common community practice is a
#                 lower temp for more deterministic completions -
#                 included as a starting point, not a sourced number.
# ==========================================================

get_mode_flags()
{

    local FAMILY="$1"
    local MODE="$2"


    case "$FAMILY" in

    qwen36)

        case "$MODE" in

        code)
            echo "--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 0.0"
            ;;

        general)
            echo "--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 1.5"
            ;;

        instruct)
            echo "--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 1.5"
            ;;

        creative)
            # Unofficial heuristic - see notes above. Starting point only.
            echo "--temp 1.15 --top-p 0.95 --top-k 40 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 1.8"
            ;;

        esac
        ;;


    qwen36-compact)

        # Same base model, but these builds are used for a narrow
        # task (prompt generation), so keep "general" tight rather
        # than switching to the higher-temp thinking preset.

        case "$MODE" in

        code)
            echo "--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 0.0"
            ;;

        general)
            echo "--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 1.5"
            ;;

        esac
        ;;


    ornith)

        case "$MODE" in

        code)
            echo "--temp 0.6 --top-p 0.95 --top-k 20"
            ;;

        general)
            echo "--temp 1.0 --top-p 1.0"
            ;;

        esac
        ;;


    gptoss)

        case "$MODE" in

        general)
            echo "--temp 1.0 --top-p 1.0"
            ;;

        code)
            # Unofficial - see notes above. Starting point only.
            echo "--temp 0.3 --top-p 0.9"
            ;;

        esac
        ;;


    *)
        echo ""
        ;;

    esac

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


    local MODE_FLAGS=""
    if [[ -n "$SELECTED_MODE" ]]
    then
        MODE_FLAGS=$(get_mode_flags "$FAMILY" "$SELECTED_MODE")
    fi


    echo
    echo "======================================"
    echo "Starting:"
    echo "$MODEL"

    if [[ -n "$SELECTED_MODE" ]]
    then
        echo "Mode: $SELECTED_MODE ($MODE_FLAGS)"
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



    if [[ -n "$MODE_FLAGS" ]]
    then
        # shellcheck disable=SC2206
        LLAMA_ARGS+=($MODE_FLAGS)
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
